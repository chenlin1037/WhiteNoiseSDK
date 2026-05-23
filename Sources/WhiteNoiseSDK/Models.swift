//
//  Models.swift
//  WhiteNoiseSDK
//

// MARK: - EngineState

/// 引擎当前的播放状态。
public enum EngineState: Equatable {
    case idle
    case loading
    case playing
    case paused
}

// MARK: - EngineError

/// 引擎可能抛出的错误。
public enum EngineError: LocalizedError {
    case tooManyTracks(limit: Int)
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
