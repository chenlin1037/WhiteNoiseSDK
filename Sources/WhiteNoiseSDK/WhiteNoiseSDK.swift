import Foundation

//
//  WhiteNoiseSDK.swift
//  WhiteNoiseSDK
//
//  公开入口 —— 宿主项目只需 import WhiteNoiseSDK
//

/// SDK 版本
public let WhiteNoiseSDKVersion = "1.0.6"

// ⚠️ 修复：添加统一的日志系统
/// 日志级别
public enum WNLogLevel: Int {
    case off = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4
    
    var description: String {
        switch self {
        case .off: return "OFF"
        case .error: return "ERROR"
        case .warning: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }
}

/// 日志配置
public struct WNLogConfig {
    public static var level: WNLogLevel = .warning
    public static var handler: ((WNLogLevel, String) -> Void)? = nil
}

/// 内部日志函数
func wn_log(_ level: WNLogLevel, _ message: String, file: String = #file, line: Int = #line) {
    guard level.rawValue <= WNLogConfig.level.rawValue else { return }
    
    // 跨平台获取文件名
    let fileName = (file as NSString).lastPathComponent
    
    let formattedMessage = "[WhiteNoiseSDK][\(level.description)] [\(fileName):\(line)] \(message)"
    
    if let handler = WNLogConfig.handler {
        handler(level, formattedMessage)
    } else {
        print(formattedMessage)
    }
}

// 通过 typealiases 让宿主无需了解内部模块结构
public typealias WNEngine        = WhiteNoiseEngine
public typealias WNEngineState   = EngineState
public typealias WNEngineError   = EngineError
public typealias WNAudioTrack    = AudioTrack
public typealias WNConfiguration = WhiteNoiseEngine.Configuration
