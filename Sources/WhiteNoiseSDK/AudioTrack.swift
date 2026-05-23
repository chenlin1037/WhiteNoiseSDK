//
//  AudioTrack.swift
//  WhiteNoiseSDK
//

import AVFoundation

public final class AudioTrack: Identifiable, ObservableObject {
    public let id: String
    public let displayName: String
    public let artworkName: String?
    public let player: AVAudioPlayerNode

    @MainActor @Published public private(set) var volume: Float

    public init(
        id: String,
        player: AVAudioPlayerNode,
        volume: Float = 1.0,
        displayName: String? = nil,
        artworkName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.artworkName = artworkName
        self.player = player
        self._volume = Published(initialValue: volume)
        player.volume = volume
    }

    @MainActor
    public func applyUIVolume(_ value: Float) {
        volume = value
    }
}
