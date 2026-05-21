//
//  AudioSessionManager.swift
//  WhiteNoiseSDK
//
//  internal —— 不暴露给宿主项目
//

import AVFoundation

final class AudioSessionManager {

    func configure() {
        #if os(iOS) || os(watchOS) || os(tvOS)
        do {
            try activateForPlayback()
        } catch {
            wn_log(.error, "AudioSession 配置失败: \(error)")
        }
        #endif
    }

    #if os(iOS) || os(watchOS) || os(tvOS)
    func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
    #endif
}
