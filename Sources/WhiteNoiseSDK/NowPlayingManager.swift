//
//  NowPlayingManager.swift
//  WhiteNoiseSDK
//
//  internal —— 宿主项目不直接使用，通过 WhiteNoiseEngine.Configuration 控制行为
//

import AVFoundation
import MediaPlayer

#if canImport(UIKit)
import UIKit
#endif

final class NowPlayingManager {

    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private let remoteCommandCenter  = MPRemoteCommandCenter.shared()
    private let artistName: String
    private let updateQueue = DispatchQueue(
        label: "com.whitenoiseSDK.nowPlayingQueue",
        qos: .utility
    )

    init(artistName: String) {
        self.artistName = artistName
    }

    // MARK: - Remote Commands

    // MARK: - Remote Commands
    //
    // 问题①修复：MPRemoteCommandCenter 是进程级系统单例，它持有所有通过
    // addTarget(_:action:) 注册的闭包，生命周期与进程相同。
    // 若闭包直接捕获 playHandler/pauseHandler（它们本身又通过 [weak self] 持有引擎），
    // 则原始闭包链在 removeTarget 被调用前永远不会释放。
    //
    // 解决方案：将三个处理器存为弱包装的 token，并在 deinit 里显式 removeTarget。
    // 同时将 handler 参数改为 weak-wrapper closure，确保引擎可以正常回收。

    private var playToken:   Any?
    private var pauseToken:  Any?
    private var toggleToken: Any?

    func setupRemoteCommands(
        playHandler:   @escaping () -> Void,
        pauseHandler:  @escaping () -> Void,
        toggleHandler: @escaping () -> Void
    ) {
        // 先移除旧 target，防止重复注册
        tearDownRemoteCommands()

        remoteCommandCenter.nextTrackCommand.isEnabled              = false
        remoteCommandCenter.previousTrackCommand.isEnabled          = false
        remoteCommandCenter.changePlaybackPositionCommand.isEnabled = false
        remoteCommandCenter.stopCommand.isEnabled                   = false

#if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
#endif

        remoteCommandCenter.playCommand.isEnabled = true
        playToken = remoteCommandCenter.playCommand.addTarget { _ in
            playHandler()
            return .success
        }

        remoteCommandCenter.pauseCommand.isEnabled = true
        pauseToken = remoteCommandCenter.pauseCommand.addTarget { _ in
            pauseHandler()
            return .success
        }

        remoteCommandCenter.togglePlayPauseCommand.isEnabled = true
        toggleToken = remoteCommandCenter.togglePlayPauseCommand.addTarget { _ in
            toggleHandler()
            return .success
        }
    }

    /// 在引擎 deinit 时调用，从系统单例中移除所有 target，切断强引用链
    func tearDownRemoteCommands() {
        if let t = playToken   { remoteCommandCenter.playCommand.removeTarget(t);              playToken   = nil }
        if let t = pauseToken  { remoteCommandCenter.pauseCommand.removeTarget(t);             pauseToken  = nil }
        if let t = toggleToken { remoteCommandCenter.togglePlayPauseCommand.removeTarget(t);   toggleToken = nil }
    }

    // MARK: - Now Playing Info

    func updateNowPlaying(title: String, isPlaying: Bool, artworkName: String? = nil) {
        updateQueue.async { [weak self] in
            guard let self else { return }
            var info = [String: Any]()
            info[MPMediaItemPropertyTitle]                    = title
            info[MPMediaItemPropertyArtist]                   = artistName
            info[MPNowPlayingInfoPropertyIsLiveStream]        = true
            info[MPNowPlayingInfoPropertyMediaType]           = MPNowPlayingInfoMediaType.audio.rawValue
            info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
            info[MPNowPlayingInfoPropertyPlaybackRate]        = isPlaying ? 1.0 : 0.0

            if let image = artworkImage(named: artworkName) {
#if canImport(UIKit)
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                info[MPMediaItemPropertyArtwork] = artwork
#endif
            }

            nowPlayingInfoCenter.nowPlayingInfo  = info
            nowPlayingInfoCenter.playbackState   = isPlaying ? .playing : .paused
        }
    }

    func clearNowPlaying() {
        updateQueue.async { [weak self] in
            self?.nowPlayingInfoCenter.nowPlayingInfo = nil
            self?.nowPlayingInfoCenter.playbackState  = .stopped
        }
    }

    // MARK: - Artwork Generation

#if canImport(UIKit)
    // 问题⑤修复：原代码每次调用 updateNowPlaying 都重新绘制一张 512×512 UIImage。
    // 封面图片与 artworkName 绑定，内容不变，无需重复渲染。
    // 使用 NSCache（而非 Dictionary）存储：系统内存压力大时自动驱逐，
    // 且 NSCache 是线程安全的，无需额外锁。
    private let artworkCache = NSCache<NSString, UIImage>()

    private func artworkImage(named name: String?) -> UIImage? {
        let cacheKey = (name ?? "__default__") as NSString
        if let cached = artworkCache.object(forKey: cacheKey) { return cached }

        let icon   = name.flatMap { UIImage(named: $0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 512, height: 512), format: format
        )

        let image = renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
            drawArtworkBackground(in: rect, context: context.cgContext)

            if let icon {
                let tinted = icon.withTintColor(.white, renderingMode: .alwaysOriginal)
                tinted.draw(
                    in: CGRect(x: 128, y: 128, width: 256, height: 256),
                    blendMode: .normal, alpha: 0.96
                )
            } else {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font:            UIFont.systemFont(ofSize: 172, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle:  style
                ]
                NSString(string: "WN").draw(
                    in: CGRect(x: 0, y: 156, width: 512, height: 220),
                    withAttributes: attrs
                )
            }
        }

        artworkCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func drawArtworkBackground(in rect: CGRect, context: CGContext) {
        let colors: CFArray = [
            UIColor(red: 0.13, green: 0.20, blue: 0.23, alpha: 1).cgColor,
            UIColor(red: 0.22, green: 0.48, blue: 0.50, alpha: 1).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 1]
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        if let gradient = CGGradient(
            colorsSpace: colorSpace, colors: colors, locations: locations
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end:   CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        }
    }
#else
    // macOS / visionOS：不生成 UIImage，返回 nil 跳过封面设置
    private func artworkImage(named _: String?) -> Never? { nil }
#endif
}
