//
//  EngineTypes.swift
//  WhiteNoiseSDK
//
import Foundation
// MARK: - EngineState

/// 引擎播放状态
public enum EngineState: Equatable {
    /// 无轨道，引擎空闲
    case idle
    /// 正在加载音频文件
    case loading
    /// 播放中
    case playing
    /// 已暂停
    case paused
}

// MARK: - TrackSnapshot

/// 面向 UI 的轻量轨道快照。
///
/// 该模型不持有 `AVAudioPlayerNode` 等实时音频对象，适合 SwiftUI 列表、
/// Slider 和状态展示订阅。
public struct TrackSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let artworkName: String?
    public let volume: Float
    public let isPlaying: Bool

    public init(
        id: String,
        displayName: String,
        artworkName: String? = nil,
        volume: Float,
        isPlaying: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.artworkName = artworkName
        self.volume = volume
        self.isPlaying = isPlaying
    }
}

// MARK: - EngineError

/// 引擎错误
public enum EngineError: LocalizedError {
    /// 超出最大同时播放轨道数
    case tooManyTracks(limit: Int)
    /// 引擎对象已释放
    case engineDeallocated

    public var errorDescription: String? {
        switch self {
        case let .tooManyTracks(limit):
            return "最多同时播放 \(limit) 个声音，请先关闭一些声音。"
        case .engineDeallocated:
            return "音频引擎已释放。"
        }
    }
}
