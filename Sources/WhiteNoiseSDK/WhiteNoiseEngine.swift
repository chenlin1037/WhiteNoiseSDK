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
        didSet { scheduleNowPlayingUpdate() }
    }

    /// 面向 SwiftUI 的轻量状态快照，不包含任何实时音频节点。
    @MainActor @Published public private(set) var trackSnapshots: [TrackSnapshot] = [] {
        didSet { scheduleNowPlayingUpdate() }
    }

    /// 引擎当前状态
    @MainActor @Published public private(set) var state: EngineState = .idle {
        didSet {
            updateSnapshotPlaybackState()
            scheduleNowPlayingUpdate()
        }
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
    private let audioQueueSpecificKey = DispatchSpecificKey<UInt8>()

    // MARK: - Fade（只在 audioQueue 访问）

    private var fadeTimers: [String: DispatchSourceTimer] = [:]
    private var uiVolumeTimers: [String: DispatchSourceTimer] = [:]
    private var pendingUIVolumes: [String: Float] = [:]

    // MARK: - 业务依赖

    private let cache:   AudioCache
    private let loader:  NetworkLoader
    private let session: AudioSessionManager
    private var nowPlaying: NowPlayingManager?
    @MainActor private var nowPlayingUpdateTask: Task<Void, Never>?

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

        audioQueue.setSpecific(key: audioQueueSpecificKey, value: 1)
        session.configure()
        observeInterruptions()
        observeRouteChanges()
        setupNowPlayingCommands()
    }

    deinit {
        // 问题⑥修复：原 deinit 只调用 cancellables.removeAll()，
        // 遗漏了以下两类资源：
        //
        // a) fadeTimers：DispatchSourceTimer 在 deinit 后仍在后台运行，
        //    持有 players 字典的强引用，延迟 AVAudioPlayerNode 的释放。
        //
        // b) players / engine：AVAudioEngine 被操作系统音频子系统持有，
        //    若不显式 stop() + detach()，可能出现"engine was not stopped"日志，
        //    且 HAL 层资源（I/O 线程、ring buffer）不会立即归还。
        //
        // 注意：deinit 不可 await，所以 audioQueue 用 sync 确保立即清理完毕。
        cancellables.removeAll()
        nowPlaying?.tearDownRemoteCommands()
        nowPlayingUpdateTask?.cancel()

        let cleanup = { [self] in
            fadeTimers.values.forEach { $0.cancel() }
            fadeTimers.removeAll()
            uiVolumeTimers.values.forEach { $0.cancel() }
            uiVolumeTimers.removeAll()
            pendingUIVolumes.removeAll()
            resetEngine()
        }

        // 在 audioQueue 上同步清理，保证 deinit 返回前资源已释放。
        // 若最后一次强引用恰好在 audioQueue 闭包尾部释放，直接执行以避免 sync 自锁。
        if DispatchQueue.getSpecific(key: audioQueueSpecificKey) != nil {
            cleanup()
        } else {
            audioQueue.sync(execute: cleanup)
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
            trackSnapshots.removeAll { $0.id == id }
            if tracks.isEmpty {
                state = .idle
                lastPlayingSoundName = nil
                currentMixName = nil
            }
        }

        audioQueue.async { [weak self] in
            guard let self, self.players[id] != nil else { return }
            self.startFade(id: id, to: 0, duration: fadeDuration) { [weak self] in
                self?.detachPlayer(id: id)
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
            self.startFade(id: id, to: volume, duration: fade)
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
                            guard self.players[id] != nil
                                    || self.players.count < self.configuration.maxConcurrentTracks else {
                                throw EngineError.tooManyTracks(
                                    limit: self.configuration.maxConcurrentTracks
                                )
                            }
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
            guard let self else { return }
            let clampedVolume = max(0, min(1, volume))
            let displayName = name ?? id
            let track = AudioTrack(
                id: id,
                player: nil,
                volume: clampedVolume,
                displayName: displayName,
                artworkName: id
            )
            self.tracks[id] = track
            self.upsertTrackSnapshot(
                TrackSnapshot(
                    id: id,
                    displayName: displayName,
                    artworkName: id,
                    volume: clampedVolume,
                    isPlaying: true
                )
            )
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
    private func scheduleNowPlayingUpdate() {
        guard configuration.nowPlayingEnabled, nowPlaying != nil else { return }
        nowPlayingUpdateTask?.cancel()
        nowPlayingUpdateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.updateNowPlayingIfNeeded()
        }
    }

    @MainActor
    private func updateNowPlayingIfNeeded() {
        guard configuration.nowPlayingEnabled, let nowPlaying else { return }

        guard !trackSnapshots.isEmpty else {
            nowPlaying.clearNowPlaying()
            return
        }

        let title: String
        if let mixName = currentMixName {
            title = mixName
        } else if trackSnapshots.count == 1 {
            title = trackSnapshots.first?.displayName ?? lastPlayingSoundName ?? "White Noise"
        } else {
            title = trackSnapshots
                .sorted { $0.displayName < $1.displayName }
                .map(\.displayName)
                .joined(separator: "、")
        }

        let artworkName = trackSnapshots
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
        // 预排两段：当前段被 render pipeline 消费后，立即在 audioQueue 上补排一段。
        // 这样队列里始终尽量保留下一段音频，UI 主线程繁忙时也不依赖即时回调续播。
        scheduleNextLoopSegment(player: player, audioFile: audioFile, id: id)
        scheduleNextLoopSegment(player: player, audioFile: audioFile, id: id)
    }

    private func scheduleNextLoopSegment(
        player: AVAudioPlayerNode,
        audioFile: AVAudioFile,
        id: String
    ) {
        let frameCount = AVAudioFrameCount(
            min(audioFile.length, AVAudioFramePosition(AVAudioFrameCount.max))
        )
        guard frameCount > 0 else { return }

        player.scheduleSegment(
            audioFile,
            startingFrame: 0,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataConsumed
        ) { [weak self, weak audioFile, weak player] _ in
            self?.audioQueue.async { [weak self, weak audioFile, weak player] in
                guard let self,
                      let audioFile,
                      let player,
                      self.players[id] === player else { return }
                self.scheduleNextLoopSegment(player: player, audioFile: audioFile, id: id)
            }
        }
    }

    private func detachPlayer(id: String) {
        cancelFade(id: id)
        uiVolumeTimers[id]?.cancel()
        uiVolumeTimers.removeValue(forKey: id)
        pendingUIVolumes.removeValue(forKey: id)
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
            trackSnapshots.removeAll()
            state = .idle
            if clearNames {
                lastPlayingSoundName = nil
                currentMixName = nil
            }
        }
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.fadeTimers.values.forEach { $0.cancel() }
            self.fadeTimers.removeAll()
            self.uiVolumeTimers.values.forEach { $0.cancel() }
            self.uiVolumeTimers.removeAll()
            self.pendingUIVolumes.removeAll()
            self.resetEngine()
        }
    }

    // MARK: - Fade（在 audioQueue 发起）

    private func cancelFade(id: String) {
        fadeTimers[id]?.cancel()
        fadeTimers.removeValue(forKey: id)
    }

    private func startFade(
        id: String,
        to target: Float,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        guard let player = players[id] else { return }
        cancelFade(id: id)

        let startVolume   = player.volume
        let clampedTarget = max(0, min(1, target))

        guard duration > 0, abs(startVolume - clampedTarget) > 0.0001 else {
            player.volume = clampedTarget
            syncUIVolume(id: id, volume: clampedTarget)
            completion?()
            return
        }

        let startDB  = 20 * log10(max(0.0001, startVolume))
        let targetDB = 20 * log10(max(0.0001, clampedTarget))
        let steps    = max(2, Int(duration * 60))
        let interval = duration / Double(steps)
        let uiStride = max(1, Int(ceil(0.1 / interval)))
        var step = 0

        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        fadeTimers[id] = timer

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.fadeTimers[id] === timer, self.players[id] === player else {
                timer.cancel()
                return
            }

            step += 1
            let t          = Float(step) / Float(steps)
            let currentDB  = startDB + (targetDB - startDB) * t
            let newVolume  = (step == steps) ? clampedTarget : pow(10, currentDB / 20)
            player.volume  = newVolume

            if step == steps || step.isMultiple(of: uiStride) {
                self.syncUIVolume(id: id, volume: newVolume, force: step == steps)
            }

            if step >= steps {
                self.fadeTimers.removeValue(forKey: id)
                timer.cancel()
                completion?()
            }
        }

        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(5)
        )
        timer.resume()
    }

    // MARK: - 主线程状态工具

    @MainActor
    private func setStateOnMain(_ newState: EngineState) {
        state = newState
    }

    @MainActor
    private func upsertTrackSnapshot(_ snapshot: TrackSnapshot) {
        if let index = trackSnapshots.firstIndex(where: { $0.id == snapshot.id }) {
            trackSnapshots[index] = snapshot
        } else {
            trackSnapshots.append(snapshot)
        }
    }

    @MainActor
    private func updateSnapshotPlaybackState() {
        let isPlaying = state == .playing
        trackSnapshots = trackSnapshots.map {
            TrackSnapshot(
                id: $0.id,
                displayName: $0.displayName,
                artworkName: $0.artworkName,
                volume: $0.volume,
                isPlaying: isPlaying
            )
        }
    }

    private func syncUIVolume(id: String, volume: Float, force: Bool = false) {
        pendingUIVolumes[id] = volume

        if force {
            flushUIVolume(id: id)
            return
        }

        guard uiVolumeTimers[id] == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        uiVolumeTimers[id] = timer
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.uiVolumeTimers.removeValue(forKey: id)
            timer.cancel()
            self.flushUIVolume(id: id)
        }
        timer.schedule(deadline: .now() + 0.1, leeway: .milliseconds(10))
        timer.resume()
    }

    private func flushUIVolume(id: String) {
        uiVolumeTimers[id]?.cancel()
        uiVolumeTimers.removeValue(forKey: id)
        guard let volume = pendingUIVolumes.removeValue(forKey: id) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            tracks[id]?.applyUIVolume(volume)

            guard let index = trackSnapshots.firstIndex(where: { $0.id == id }) else { return }
            let snapshot = trackSnapshots[index]
            trackSnapshots[index] = TrackSnapshot(
                id: snapshot.id,
                displayName: snapshot.displayName,
                artworkName: snapshot.artworkName,
                volume: volume,
                isPlaying: snapshot.isPlaying
            )
        }
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
