//
//  NowPlayingManager.swift
//  WhiteNoiseSDK
//

import AVFoundation
import Foundation
import MediaPlayer
import UIKit

public final class NowPlayingManager {
    public static let shared = NowPlayingManager()

    private let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
    private let remoteCommandCenter = MPRemoteCommandCenter.shared()

    private var playToken: Any?
    private var pauseToken: Any?
    private var toggleToken: Any?

    private let artworkCache = NSCache<NSString, UIImage>()

    private init() {}

    // MARK: - Remote Commands

    public func setupRemoteCommands(
        playHandler: @escaping () -> Void,
        pauseHandler: @escaping () -> Void,
        toggleHandler: @escaping () -> Void
    ) {
        tearDownRemoteCommands()
        remoteCommandCenter.nextTrackCommand.isEnabled = false
        remoteCommandCenter.previousTrackCommand.isEnabled = false
        remoteCommandCenter.changePlaybackPositionCommand.isEnabled = false
        remoteCommandCenter.stopCommand.isEnabled = false
        UIApplication.shared.beginReceivingRemoteControlEvents()
        remoteCommandCenter.playCommand.isEnabled = true
        playToken = remoteCommandCenter.playCommand.addTarget { _ in playHandler(); return .success }
        remoteCommandCenter.pauseCommand.isEnabled = true
        pauseToken = remoteCommandCenter.pauseCommand.addTarget { _ in pauseHandler(); return .success }
        remoteCommandCenter.togglePlayPauseCommand.isEnabled = true
        toggleToken = remoteCommandCenter.togglePlayPauseCommand.addTarget { _ in toggleHandler(); return .success }
    }

    public func tearDownRemoteCommands() {
        if let t = playToken { remoteCommandCenter.playCommand.removeTarget(t); playToken = nil }
        if let t = pauseToken { remoteCommandCenter.pauseCommand.removeTarget(t); pauseToken = nil }
        if let t = toggleToken { remoteCommandCenter.togglePlayPauseCommand.removeTarget(t); toggleToken = nil }
    }

    // MARK: - Now Playing Info

    public func updateNowPlaying(
        title: String,
        artist: String = "WhiteNoiseSDK",
        isPlaying: Bool,
        artworkName: String? = nil
    ) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let image = artworkImage(named: artworkName) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        nowPlayingInfoCenter.nowPlayingInfo = info
    }

    public func clearNowPlaying() {
        nowPlayingInfoCenter.nowPlayingInfo = nil
    }

    // MARK: - Artwork

    private func artworkImage(named name: String?) -> UIImage? {
        let cacheKey = (name ?? "__default__") as NSString
        if let cached = artworkCache.object(forKey: cacheKey) { return cached }
        let icon = name.flatMap { UIImage(named: $0) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format)
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: 512, height: 512)
            drawArtworkBackground(in: rect, context: ctx.cgContext)
            if let icon {
                icon.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 128, y: 128, width: 256, height: 256), blendMode: .normal, alpha: 0.96)
            } else {
                let para = NSMutableParagraphStyle(); para.alignment = .center
                NSString(string: "WN").draw(
                    in: CGRect(x: 0, y: 156, width: 512, height: 220),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 172, weight: .semibold),
                        .foregroundColor: UIColor.white,
                        .paragraphStyle: para,
                    ]
                )
            }
        }
        artworkCache.setObject(image, forKey: cacheKey)
        return image
    }

    private func drawArtworkBackground(in rect: CGRect, context: CGContext) {
        let colors = [
            UIColor(red: 0.13, green: 0.20, blue: 0.23, alpha: 1).cgColor,
            UIColor(red: 0.22, green: 0.48, blue: 0.50, alpha: 1).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0, 1]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
            context.drawLinearGradient(gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
    }
}
