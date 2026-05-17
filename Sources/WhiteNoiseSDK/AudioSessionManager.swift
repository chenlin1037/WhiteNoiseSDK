//
//  AudioSessionManager.swift
//  WhiteNoiseSDK
//
//  internal —— 不暴露给宿主项目
//

import AVFoundation

final class AudioSessionManager {

    func configure() {
        do {
            try activateForPlayback()
        } catch {
            print("[WhiteNoiseSDK] AudioSession 配置失败: \(error)")
        }
    }

    func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }
}
