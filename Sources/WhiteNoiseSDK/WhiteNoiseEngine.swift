//
//  WhiteNoiseEngine.swift
//  WhiteNoiseSDK
//

@preconcurrency import AVFoundation
import Combine

// MARK: - Public Types



// MARK: - WhiteNoiseEngine

public final class WhiteNoiseEngine: ObservableObject, @unchecked Sendable {
    public static let shared = WhiteNoiseEngine()
    public static let maxConcurrentTracks = 6

    // MARK: - UI 状态（只在 MainActor 读写）

    @MainActor @Published public private(set) var tracks: [String: AudioTrack] = [:] {
        didSet { updateNowPlaying() }
    }

    @MainActor @Published public private(set) var state: EngineState = .idle {
        didSet { updateNowPlaying() }
    }

    @MainActor private var lastPlayingSoundName: String?
    @MainActor private var currentMixName: String?

    // MARK: - 音频硬件（只在 audioQueue 访问）

    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var audioFiles: [String: AVAudioFile] = [:]

    private let audioQueue = DispatchQueue(
        label: "com.whitenoise.audioQueue",
        qos: .userInitiated
    )

    // MARK: - Fade 控制（只在 audioQueue 访问）

    private var fadeTasks: [String: Task<Void, Never>] = [:]

    // MARK: - 业务依赖

    private let cache = AudioCache()
    private let loader = NetworkLoader()
    private let session = AudioSessionManager()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init / Deinit

    private init() {
        session.configure()
        observeInterruptions()
        observeRouteChanges()
        setupNowPlayingCommands()
    }

    deinit {
        cancellables.removeAll()
        NowPlayingManager.shared.tearDownRemoteCommands()
        audioQueue.sync { [self] in
            fadeTasks.values.forEach { $0.cancel() }
            fadeTasks.removeAll()
            resetEngine()
        }
    }

    // MARK: - Now Playing 命令

    private func setupNowPlayingCommands() {
        NowPlayingManager.shared.setupRemoteCommands(
            playHandler: { [weak self] in self?.resumeAll() },
            pauseHandler: { [weak self] in self?.pauseAll() },
            toggleHandler: { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.state == .playing { self.pauseAll() } else { self.resumeAll() }
                }
            }
        )
    }

    @MainActor
    private func updateNowPlaying() {
        guard !tracks.isEmpty else {
            NowPlayingManager.shared.clearNowPlaying()
            return
        }
        NowPlayingManager.shared.updateNowPlaying(
            title: currentNowPlayingTitle,
            isPlaying: state == .playing,
            artworkName: currentArtworkName
        )
    }

    // MARK: - Public API

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

    public func play(url: URL, id: String, volume: Float = 1.0, name: String? = nil) async throws {
        await MainActor.run {
            if let name { self.lastPlayingSoundName = name }
            self.currentMixName = nil
        }
        try await playInternal(url: url, id: id, volume: volume, name: name)
    }

    private func playInternal(url: URL, id: String, volume: Float = 1.0, name: String? = nil) async throws {
        await MainActor.run {
            if let name { self.lastPlayingSoundName = name }
        }

        let (trackCount, hasExisting) = await MainActor.run {
            (tracks.count, tracks[id] != nil)
        }

        guard hasExisting || trackCount < Self.maxConcurrentTracks else {
            throw EngineError.tooManyTracks(limit: Self.maxConcurrentTracks)
        }

        await MainActor.run { state = .loading }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    continuation.resume(throwing: EngineError.engineDeallocated)
                    return
                }
                do {
                    let fileURL = try await self.loader.fetch(url: url, cache: self.cache)
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

    public func setMasterVolume(_ volume: Float) {
        audioQueue.async { [weak self] in
            self?.engine.mainMixerNode.outputVolume = max(0, min(1, volume))
        }
    }

    public func pauseAll() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.players.values.forEach { $0.pause() }
            self.engine.pause()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = .paused
            }
        }
    }

    public func resumeAll() {
        audioQueue.async { [weak self] in
            guard let self, !self.players.isEmpty else { return }
            do {
                try self.startEngineIfNeeded()
                self.players.values.forEach { $0.play() }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.state = .playing
                }
            } catch {
                print("[WhiteNoiseSDK] resumeAll 失败: \(error)")
            }
        }
    }

    public func stopAll() {
        stopAll(clearNames: true)
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
            self.fadeTasks.values.forEach { $0.cancel() }
            self.fadeTasks.removeAll()
            self.resetEngine()
        }
    }

    // MARK: - 音频硬件私有方法（只在 audioQueue 调用）

    @discardableResult
    private func attachPlayer(id: String, audioFile: AVAudioFile, volume: Float) -> AVAudioPlayerNode {
        if players[id] != nil { detachPlayer(id: id) }
        let player = AVAudioPlayerNode()
        player.volume = volume
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
        players[id] = player
        audioFiles[id] = audioFile
        scheduleLoop(player: player, audioFile: audioFile, id: id)
        return player
    }

    private func scheduleLoop(player: AVAudioPlayerNode, audioFile: AVAudioFile, id: String) {
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

    @MainActor
    private var currentNowPlayingTitle: String {
        if let mixName = currentMixName { return mixName }
        if tracks.count == 1 { return tracks.values.first?.displayName ?? "White Noise" }
        return tracks.values
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: "、")
    }

    @MainActor
    private var currentArtworkName: String? {
        tracks.values
            .sorted { $0.displayName < $1.displayName }
            .compactMap(\.artworkName)
            .first
    }

    // MARK: - Fade（在 audioQueue 发起）

    private func cancelFade(id: String) {
        fadeTasks[id]?.cancel()
        fadeTasks.removeValue(forKey: id)
    }

    private func runFade(id: String, to target: Float, duration: TimeInterval) async {
        guard let player = players[id] else { return }
        let startVolume = player.volume
        let clampedTarget = max(0, min(1, target))

        guard duration > 0, abs(startVolume - clampedTarget) > 0.0001 else {
            player.volume = clampedTarget
            await MainActor.run { [weak self] in self?.tracks[id]?.applyUIVolume(clampedTarget) }
            return
        }

        let startDB = 20 * log10(max(0.0001, startVolume))
        let targetDB = 20 * log10(max(0.0001, clampedTarget))
        let steps = max(30, Int(duration * 60))
        let interval = UInt64(duration / Double(steps) * 1_000_000_000)

        for step in 1 ... steps {
            guard !Task.isCancelled else { return }
            let t = Float(step) / Float(steps)
            let currentDB = startDB + (targetDB - startDB) * t
            let newVolume = (step == steps) ? clampedTarget : pow(10, currentDB / 20)
            player.volume = newVolume
            let v = newVolume
            await MainActor.run { [weak self] in self?.tracks[id]?.applyUIVolume(v) }
            if step < steps { try? await Task.sleep(nanoseconds: interval) }
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
        guard let info = notification.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
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
        guard let info = notification.userInfo,
              let reasonVal = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonVal),
              reason == .oldDeviceUnavailable else { return }
        pauseAll()
    }
}
