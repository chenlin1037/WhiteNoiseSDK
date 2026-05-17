# WhiteNoiseSDK

轻量级白噪音音频引擎，封装为可复用的 Swift Package。

## 功能

- 最多 6 条轨道同时播放（可配置）
- 自动磁盘缓存 + LRU 淘汰（默认 500 MB）
- 无缝循环播放
- 对数曲线淡入 / 淡出
- 锁屏 / 控制中心 Now Playing 集成
- 音频中断 & 路由变化自动处理
- 完整 `async/await` API，兼容 SwiftUI `ObservableObject`

## 要求

- iOS 16+
- Swift 5.9+

---

## 安装

### Swift Package Manager

在 Xcode 中选择 **File → Add Package Dependencies**，输入仓库地址，或在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/chenlin1037/WhiteNoiseSDK.git", from: "1.0.0")
]
```

---

## 快速开始

### 1. Info.plist 配置

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

### 2. 基本播放

```swift
import WhiteNoiseSDK

// 使用全局单例（默认配置）
let engine = WhiteNoiseEngine.shared

// 播放单个声音
Task {
    try await engine.play(
        url: URL(string: "https://example.com/rain.mp3")!,
        id: "rain",
        volume: 0.8,
        name: "雨声"
    )
}
```

### 3. 自定义配置

```swift
let config = WhiteNoiseEngine.Configuration(
    maxConcurrentTracks: 4,      // 最多 4 轨
    artistName: "MyApp",          // Now Playing 艺术家名称
    nowPlayingEnabled: true,      // 启用锁屏控制
    maxDiskCacheBytes: 200 * 1024 * 1024  // 200 MB 缓存
)
let engine = WhiteNoiseEngine(configuration: config)
```

### 4. 批量混合播放

```swift
let items: [(soundID: String, volume: Float, url: URL, name: String)] = [
    ("rain",  0.7, rainURL,  "雨声"),
    ("wind",  0.5, windURL,  "风声"),
    ("fire",  0.6, fireURL,  "篝火"),
]

Task {
    try await engine.applyMix(items: items, mixName: "森林夜雨")
}
```

### 5. 音量控制

```swift
// 单轨淡变（默认 0.3 秒）
engine.setVolume(0.5, for: "rain")

// 自定义淡变时长
engine.setVolume(0.3, for: "wind", fade: 1.0)

// 主音量
engine.setMasterVolume(0.8)
```

### 6. 移除轨道

```swift
// 淡出后移除（默认 1 秒）
engine.remove(id: "rain")

// 自定义淡出时长
engine.remove(id: "wind", fadeDuration: 2.0)
```

### 7. 全局控制

```swift
engine.pauseAll()
engine.resumeAll()
engine.stopAll()
```

### 8. SwiftUI 集成

```swift
struct PlayerView: View {
    @StateObject private var engine = WhiteNoiseEngine.shared

    var body: some View {
        VStack {
            Text(engine.state == .playing ? "播放中" : "已停止")

            ForEach(Array(engine.tracks.values)) { track in
                TrackRow(track: track, engine: engine)
            }
        }
    }
}

struct TrackRow: View {
    @ObservedObject var track: AudioTrack
    let engine: WhiteNoiseEngine

    var body: some View {
        HStack {
            Text(track.displayName)
            Slider(
                value: Binding(
                    get: { track.volume },
                    set: { engine.setVolume($0, for: track.id) }
                )
            )
        }
    }
}
```

---

## 架构说明

```
WhiteNoiseSDK/
├── Sources/WhiteNoiseSDK/
│   ├── WhiteNoiseSDK.swift       # 公开入口 & TypeAliases
│   ├── WhiteNoiseEngine.swift    # 核心引擎（public）
│   ├── EngineTypes.swift         # EngineState / EngineError（public）
│   ├── AudioTrack.swift          # 轨道模型（public）
│   ├── NowPlayingManager.swift   # 锁屏集成（internal）
│   ├── AudioSessionManager.swift # AVAudioSession 封装（internal）
│   ├── AudioCache.swift          # 磁盘缓存（internal）
│   └── NetworkLoader.swift       # 网络下载（internal）
└── Tests/WhiteNoiseSDKTests/
    └── WhiteNoiseSDKTests.swift
```

### 访问控制原则

| 类型 | 访问级别 | 说明 |
|------|----------|------|
| `WhiteNoiseEngine` | `public` | 宿主项目直接使用 |
| `AudioTrack` | `public` | SwiftUI 绑定 |
| `EngineState` | `public` | 状态枚举 |
| `EngineError` | `public` | 错误处理 |
| `NowPlayingManager` | `internal` | 实现细节 |
| `AudioCache` | `internal` | 实现细节 |
| `NetworkLoader` | `internal` | 实现细节 |
| `AudioSessionManager` | `internal` | 实现细节 |

---

## 与原始项目集成迁移

| 原始代码 | SDK 代码 |
|----------|----------|
| `WhiteNoiseEngine.shared` | 不变 |
| `NowPlayingManager.shared.updateNowPlaying(...)` | 由引擎自动处理，无需手动调用 |
| `AudioTrack.applyUIVolume(_:)` | 仅供 SDK 内部使用，外部不可调用 |
| 缓存目录 `WhiteNoiseAudio` | 改为 `WhiteNoiseSDKAudio`（避免与旧缓存冲突） |
