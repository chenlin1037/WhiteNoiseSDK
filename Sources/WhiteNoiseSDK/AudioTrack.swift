//
//  AudioTrack.swift
//  WhiteNoiseSDK
//

import AVFoundation

/// 代表一条正在播放（或暂停）的音频轨道
///
/// 作为 `ObservableObject` 可直接绑定到 SwiftUI 视图：
/// ```swift
/// @ObservedObject var track: AudioTrack
/// Slider(value: Binding(
///     get: { track.volume },
///     set: { engine.setVolume($0, for: track.id) }
/// ))
/// ```
public final class AudioTrack: Identifiable, ObservableObject {

    /// 轨道唯一标识符
    public let id: String

    /// 显示名称（用于 UI 与 Now Playing）
    public let displayName: String

    /// 封面图片资源名称（Assets 中的名称）
    public let artworkName: String?

    // 仅为兼容内部旧测试/初始化路径保留；实时播放节点不应通过 UI 对象访问。
    internal let player: AVAudioPlayerNode?

    /// 当前音量（主线程只读，由引擎通过 `applyUIVolume` 更新）
    @MainActor @Published public private(set) var volume: Float

    internal init(
        id: String,
        player: AVAudioPlayerNode? = nil,
        volume: Float = 1.0,
        displayName: String? = nil,
        artworkName: String? = nil
    ) {
        self.id          = id
        self.displayName = displayName ?? id
        self.artworkName = artworkName
        self.player      = player
        self._volume     = Published(initialValue: volume)
    }

    /// 由 `WhiteNoiseEngine` 在淡变过程中调用，更新 UI 音量值
    @MainActor
    internal func applyUIVolume(_ value: Float) {
        volume = value
    }
}
