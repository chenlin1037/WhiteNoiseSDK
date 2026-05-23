//
//  AudioSessionManager.swift
//  WhiteNoiseSDK
//

import AVFoundation

public final class AudioSessionManager {

    public init() {}

    public func configure() {
        do {
            try activateForPlayback()
        } catch {
            print("[WhiteNoiseSDK] AudioSession 配置失败: \(error)")
        }
    }

    public func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
}
