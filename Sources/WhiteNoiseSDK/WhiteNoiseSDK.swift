//
//  WhiteNoiseSDK.swift
//  WhiteNoiseSDK
//
//  公开入口 —— 宿主项目只需 import WhiteNoiseSDK
//

/// SDK 版本
public let WhiteNoiseSDKVersion = "1.0.3"

// 通过 typealiases 让宿主无需了解内部模块结构
public typealias WNEngine        = WhiteNoiseEngine
public typealias WNEngineState   = EngineState
public typealias WNEngineError   = EngineError
public typealias WNAudioTrack    = AudioTrack
public typealias WNConfiguration = WhiteNoiseEngine.Configuration
