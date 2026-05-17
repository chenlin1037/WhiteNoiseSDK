//
//  EngineTypes.swift
//  WhiteNoiseSDK
//

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
