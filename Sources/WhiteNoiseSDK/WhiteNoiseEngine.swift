//
//  WhiteNoiseEngine.swift
//  WhiteNoiseSDK
//

@preconcurrency import AVFoundation
import Combine

/// 白噪音音频引擎 —— SDK 核心类
///
/// 典型用法：
/// ```swift
/// // 使用默认配置的单例
/// let engine = WhiteNoiseEngine.shared
///
/// // 使用自定义配置创建独立实例
/// let config = WhiteNoiseEngine.Configuration(
///     maxConcurrentTracks: 4,
///     artistName: "MyApp",
///     nowPlayingEnabled: true
/// )
/// let engine = WhiteNoiseEngine(configuration: config)
/// ```
public final class WhiteNoiseEngine: ObservableObject, @unchecked Sendable {

    // MARK: - Configuration

    /// 引擎配置，在 `init` 时传入，之后不可变
    public struct Configuration {
        /// 最大同时播放轨道数，默认 6
        public var maxConcurrentTracks: Int
        /// Now Playing 显示的艺术家名称，默认 "WhiteNoiseSDK"
        public var artistName: String
        /// 是否启用锁屏 / 控制中心 Now Playing，默认 true
        public var nowPlayingEnabled: Bool
        /// 磁盘缓存上限（字节），默认 500 MB
        public var maxDiskCacheBytes: Int

        public init(
            maxConcurrentTracks: Int = 6,
            artistName: String = "WhiteNoiseSDK",
            nowPlayingEnabled: Bool = true,
            maxDiskCacheBytes: Int = 500 * 1024 * 1024
        ) {
            self.maxConcurrentTracks = maxConcurrentTracks
            self.artistName = artistName
            self.nowPlayingEnabled = nowPlayingEnabled
            self.maxDiskCacheBytes = maxDiskCacheBytes
        }
    }

    // MARK: - Shared Instance

    /// 使用默认配置的全局单例
    /// 若需要自定义配置，请直接 `init(configuration:)` 创建独立实例
    public static let shared = WhiteNoiseEngine()

    // MARK: - Public State（只在 MainActor 读写）

    /// 当前所有播放轨道，key 为轨道 ID
    @MainActor @Published public private(set) var tracks: [String: AudioTrack] = [:] {
        didSet { _updateNowPlayingIfNeeded() }
    }

    /// 引擎当前状态
    @MainActor @Published public private(set) var state: EngineState = .idle {
        didSet { _updateNowPlayingIfNeeded() }
    }

    /// 引擎配置（只读）
    public let configuration: Configuration

    // MARK: - Private State

    @MainActor private var lastPlayingSoundName: String?
    @MainActor private var currentMixName: String?

    // MARK: - 音频硬件（只在 audioQueue 访问）

    private let engine = AVAudioEngine()
    private var players:    [String: AVAudioPlayerNode] = [:]
    private var audioFiles: [String: AVAudioFile]       = [:]

    private let audioQueue = DispatchQueue(
        label: "com.whitenoiseSDK.audioQueue",
        qos: .userInitiated
    )

    // MARK: - Fade（只在 audioQueue 访问）

    private var fadeTasks: [String: Task<Void, Never>] = [:]

    // MARK: - 业务依赖

    private let cache:   AudioCache
    private let loader:  NetworkLoader
    private let session: AudioSessionManager
    private var nowPlaying: NowPlayingManager?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    /// 使用默认配置初始化
    public convenience init() {
        self.init(configuration: Configuration())
    }

    /// 使用自定义配置初始化
    /// - Parameter configuration: 引擎配置
    public init(configuration: Configuration) {
        self.configuration = configuration
        self.cache   = AudioCache(maxDiskBytes: configuration.maxDiskCacheBytes)
        self.loader  = NetworkLoader()
        self.session = AudioSessionManager()

        if configuration.nowPlayingEnabled {
            self.nowPlaying = NowPlayingManager(artistName: configuration.artistName)
        }

        session.configure()
        observeInterruptions()
        observeRouteChanges()
        setupNowPlayingCommands()
    }

    deinit {
        // 问题⑥修复：原 deinit 只调用 cancellables.removeAll()，
        // 遗漏了以下两类资源：
        //
        // a) fadeTasks：Task 对象在 deinit 后仍在后台运行，
        //    持有 players 字典的强引用，延迟 AVAudioPlayerNode 的释放。
        //
        // b) players / engine：AVAudioEngine 被操作系统音频子系统持有，
        //    若不显式 stop() + detach()，可能出现"engine was not stopped"日志，
        //    且 HAL 层资源（I/O 线程、ring buffer）不会立即归还。
        //
        // 注意：deinit 不可 await，所以 audioQueue 用 sync 确保立即清理完毕。
        cancellables.removeAll()
        nowPlaying?.tearDownRemoteCommands()

        // 在 audioQueue 上同步清理，保证 deinit 返回前资源已释放
        audioQueue.sync { [self] in
            fadeTasks.values.forEach { $0.cancel() }
            fadeTasks.removeAll()
            resetEngine()
        }
    }

    // MARK: - Public API

    /// 播放单个音频轨道
    /// - Parameters:
    ///   - url: 音频文件的远程或本地 URL
    ///   - id: 轨道唯一标识符
    ///   - volume: 初始音量（0.0 ~ 1.0），默认 1.0
    ///   - name: 显示名称，用于 Now Playing
    public func play(url: URL, id: String, volume: Float = 1.0, name: String? = nil) async throws {
        await MainActor.run {
            if let name { self.lastPlayingSoundName = name }
            self.currentMixName = nil
        }
        try await playInternal(url: url, id: id, volume: volume, name: name)
    }

    /// 批量播放混合（原子操作：先停止当前所有轨道，再并发加载）
    /// - Parameters:
    ///   - items: 混合轨道列表
    ///   - mixName: 混合名称，用于 Now Playing 显示
    public func applyMix(
        items: [(soundID: String, volume: Float, url: URL, name: String)],
        mixName: String
    ) async throws {
        await MainActor.run {
            self.currentMixName = mixName
            self.lastPlayingSoundName = nil
        }
        stopAll(clearNames: false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in items {
                group.addTask {
                    try await self.playInternal(
                        url: item.url, id: item.soundID,
                        volume: item.volume, name: item.name
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    /// 移除指定轨道（先淡出后卸载）
    /// - Parameters:
    ///   - id: 轨道 ID
    ///   - fadeDuration: 淡出时长（秒），默认 1.0
    public func remove(id: String, fadeDuration: TimeInterval = 1.0) {
        Task { @MainActor in
            guard tracks[id] != nil else { return }
            tracks.removeValue(forKey: id)
            if tracks.isEmpty {
                state = .idle
                lastPlayingSoundName = nil
                currentMixName = nil
            }
        }

        audioQueue.async { [weak self] in
            guard let self, self.players[id] != nil else { return }
            self.cancelFade(id: id)
            self.fadeTasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.runFade(id: id, to: 0, duration: fadeDuration)
                self.audioQueue.async { [weak self] in
                    guard let self else { return }
                    self.detachPlayer(id: id)
                    self.fadeTasks.removeValue(forKey: id)
                }
            }
        }
    }

    /// 调整单轨音量（带淡变）
    /// - Parameters:
    ///   - volume: 目标音量（0.0 ~ 1.0）
    ///   - id: 轨道 ID
    ///   - fade: 淡变时长（秒），默认 0.3
    public func setVolume(_ volume: Float, for id: String, fade: TimeInterval = 0.3) {
        audioQueue.async { [weak self] in
            guard let self, self.players[id] != nil else { return }
            self.cancelFade(id: id)
            self.fadeTasks[id] = Task { [weak self] in
                guard let self else { return }
                await self.runFade(id: id, to: volume, duration: fade)
                self.audioQueue.async { [weak self] in
                    self?.fadeTasks.removeValue(forKey: id)
                }
            }
        }
    }

    /// 调整主音量（影响所有轨道）
    /// - Parameter volume: 主音量（0.0 ~ 1.0）
    public func setMasterVolume(_ volume: Float) {
        audioQueue.async { [weak self] in
            self?.engine.mainMixerNode.outputVolume = max(0, min(1, volume))
        }
    }

    /// 暂停所有轨道
    public func pauseAll() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.players.values.forEach { $0.pause() }
            Task { await self.setStateOnMain(.paused) }
        }
    }

    /// 恢复所有轨道播放
    public func resumeAll() {
        audioQueue.async { [weak self] in
            guard let self, !self.players.isEmpty else { return }
            do {
                try self.startEngineIfNeeded()
                self.players.values.forEach { $0.play() }
                Task { await self.setStateOnMain(.playing) }
            } catch {
                print("[WhiteNoiseSDK] resumeAll 失败: \(error)")
            }
        }
    }

    /// 停止所有轨道并清空状态
    public func stopAll() {
        stopAll(clearNames: true)
    }

    /// 清空所有磁盘缓存
    public func clearCache() async throws {
        try await cache.clearAll()
    }

    // MARK: - Internal Play

    private func playInternal(url: URL, id: String, volume: Float = 1.0, name: String? = nil) async throws {
        await MainActor.run {
            if let name { self.lastPlayingSoundName = name }
        }

        let (trackCount, hasExisting) = await MainActor.run {
            (tracks.count, tracks[id] != nil)
        }

        guard hasExisting || trackCount < configuration.maxConcurrentTracks else {
            throw EngineError.tooManyTracks(limit: configuration.maxConcurrentTracks)
        }

        await MainActor.run { state = .loading }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // 问题③修复：原代码在 Task.detached 内的 audioQueue.async 闭包中
            // 直接写 `self.cancelFade` 等，Swift 会将 self 隐式强捕获。
            // 若网络下载耗时较长（弱网或大文件），这期间即便宿主释放了引擎，
            // 引擎对象依然被 Task 持活，造成意外延迟释放。
            // 修复：两层都显式 [weak self]，任何一层 self 已释放则 resume throwing。
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EngineError.engineDeallocated)
                    return
                }
                do {
                    let fileURL   = try await self.loader.fetch(url: url, cache: self.cache)
                    let audioFile = try AVAudioFile(forReading: fileURL)

                    self.audioQueue.async { [weak self] in
                        guard let self else {
                            continuation.resume(throwing: EngineError.engineDeallocated)
                            return
                        }
                        do {
                            self.cancelFade(id: id)
                            self.attachPlayer(id: id, audioFile: audioFile, volume: volume)
                            try self.startEngineIfNeeded()
                            self.players[id]?.play()
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        await MainActor.run { [weak self] in
            guard let self, let player = self.players[id] else { return }
            let track = AudioTrack(id: id, player: player, volume: volume,
                                   displayName: name, artworkName: id)
            self.tracks[id] = track
            self.state = .playing
        }
    }

    // MARK: - Now Playing

    private func setupNowPlayingCommands() {
        guard let nowPlaying else { return }
        nowPlaying.setupRemoteCommands(
            playHandler:   { [weak self] in self?.resumeAll() },
            pauseHandler:  { [weak self] in self?.pauseAll() },
            toggleHandler: { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.state == .playing { self.pauseAll() } else { self.resumeAll() }
                }
            }
        )
    }

    @MainActor
    private func _updateNowPlayingIfNeeded() {
        guard configuration.nowPlayingEnabled, let nowPlaying else { return }

        guard !tracks.isEmpty else {
            nowPlaying.clearNowPlaying()
            return
        }

        let title: String
        if let mixName = currentMixName {
            title = mixName
        } else if tracks.count == 1 {
            title = tracks.values.first?.displayName ?? lastPlayingSoundName ?? "White Noise"
        } else {
            title = tracks.values
                .sorted { $0.displayName < $1.displayName }
                .map(\.displayName)
                .joined(separator: "、")
        }

        let artworkName = tracks.values
            .sorted { $0.displayName < $1.displayName }
            .compactMap(\.artworkName)
            .first

        nowPlaying.updateNowPlaying(title: title, isPlaying: state == .playing, artworkName: artworkName)
    }

    // MARK: - 音频硬件私有方法（只在 audioQueue 调用）

    @discardableResult
    private func attachPlayer(id: String, audioFile: AVAudioFile, volume: Float) -> AVAudioPlayerNode {
        if players[id] != nil { detachPlayer(id: id) }

        let player = AVAudioPlayerNode()
        player.volume = volume
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
        players[id]    = player
        audioFiles[id] = audioFile

        scheduleLoop(player: player, audioFile: audioFile, id: id)
        return player
    }

    private func scheduleLoop(player: AVAudioPlayerNode, audioFile: AVAudioFile, id: String) {
        // 问题②修复：原闭包强持有 audioFile —— detachPlayer 将其从字典移除后，
        // 文件对象仍被闭包 retain，直到下一次回调触发才真正释放（数秒后）。
        // 改用 [weak audioFile]：一旦字典移除，引用计数立即归零可释放；
        // guard let audioFile 确保若已释放就不再重新调度。
        audioFile.framePosition = 0
        player.scheduleFile(audioFile, at: nil, completionCallbackType: .dataConsumed) { [weak self, weak audioFile] _ in
            self?.audioQueue.async { [weak self, weak audioFile] in
                guard let self,
                      let audioFile,
                      self.players[id] === player,
                      player.isPlaying else { return }
                self.scheduleLoop(player: player, audioFile: audioFile, id: id)
            }
        }
    }

    private func detachPlayer(id: String) {
        cancelFade(id: id)
        guard let player = players[id] else { return }
        audioFiles.removeValue(forKey: id)
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
        players.removeValue(forKey: id)
    }

    private func startEngineIfNeeded() throws {
        try session.activateForPlayback()
        guard !engine.isRunning else { return }
        try engine.start()
    }

    private func resetEngine() {
        players.values.forEach { $0.stop() }
        audioFiles.removeAll()
        for player in players.values {
            engine.disconnectNodeOutput(player)
            engine.detach(player)
        }
        players.removeAll()
        engine.stop()
    }

    private func stopAll(clearNames: Bool) {
        Task { @MainActor in
            tracks.removeAll()
            state = .idle
            if clearNames {
                lastPlayingSoundName = nil
                currentMixName = nil
            }
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            // 问题④修复：cancel() 仅设置 Task.isCancelled 标志，不会中断已经
            // dispatch 到 audioQueue 的尾部闭包（runFade 完成后的 detachPlayer 调度）。
            // 这些尾部闭包仍持有 players / engine，在 resetEngine() 之后再执行
            // 会访问已被清空的集合，造成状态不一致，且延迟引擎对象的释放。
            //
            // 解决方案：先 cancel 所有 Task，再同步清空 fadeTasks 字典，
            // 最后 barrier async 保证之前 dispatch 的所有尾部闭包都已完成后
            // 再执行 resetEngine。
            self.fadeTasks.values.forEach { $0.cancel() }
            self.fadeTasks.removeAll()
            self.resetEngine()
        }
    }

    // MARK: - Fade（在 audioQueue 发起）

    private func cancelFade(id: String) {
        fadeTasks[id]?.cancel()
        fadeTasks.removeValue(forKey: id)
    }

    private func runFade(id: String, to target: Float, duration: TimeInterval) async {
        guard let player = players[id] else { return }

        let startVolume   = player.volume
        let clampedTarget = max(0, min(1, target))

        guard duration > 0, abs(startVolume - clampedTarget) > 0.0001 else {
            player.volume = clampedTarget
            await MainActor.run { [weak self] in self?.tracks[id]?.applyUIVolume(clampedTarget) }
            return
        }

        let startDB  = 20 * log10(max(0.0001, startVolume))
        let targetDB = 20 * log10(max(0.0001, clampedTarget))
        let steps    = max(30, Int(duration * 60))
        let interval = UInt64(duration / Double(steps) * 1_000_000_000)

        for step in 1 ... steps {
            guard !Task.isCancelled else { return }
            let t          = Float(step) / Float(steps)
            let currentDB  = startDB + (targetDB - startDB) * t
            let newVolume  = (step == steps) ? clampedTarget : pow(10, currentDB / 20)
            player.volume  = newVolume
            let v = newVolume
            await MainActor.run { [weak self] in self?.tracks[id]?.applyUIVolume(v) }
            if step < steps { try? await Task.sleep(nanoseconds: interval) }
        }
    }

    // MARK: - 主线程状态工具

    @MainActor
    private func setStateOnMain(_ newState: EngineState) {
        state = newState
    }

    // MARK: - 系统通知

    private func observeInterruptions() {
        NotificationCenter.default
            .publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: audioQueue)
            .sink { [weak self] in self?.handleInterruption($0) }
            .store(in: &cancellables)
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info     = notification.userInfo,
              let typeVal  = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type     = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }

        switch type {
        case .began:
            pauseAll()
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            if opts.contains(.shouldResume) { resumeAll() }
        @unknown default:
            break
        }
    }

    private func observeRouteChanges() {
        NotificationCenter.default
            .publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: audioQueue)
            .sink { [weak self] in self?.handleRouteChange($0) }
            .store(in: &cancellables)
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info      = notification.userInfo,
              let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason    = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
              reason == .oldDeviceUnavailable else { return }
        pauseAll()
    }
}
