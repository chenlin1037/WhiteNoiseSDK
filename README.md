
# WhiteNoiseSDK

A lightweight white noise audio engine, packaged as a reusable Swift Package.

## Features

- Up to 6 simultaneous audio tracks (configurable)
- Automatic disk caching with LRU eviction (500 MB default)
- Seamless loop playback
- Logarithmic fade in / fade out curves
- Lock screen / Control Center Now Playing integration
- Automatic audio interruption & route change handling
- Full `async/await` API, compatible with SwiftUI `ObservableObject`

## Requirements

- iOS 16+
- Swift 5.9+

---

## Installation

### Swift Package Manager

In Xcode, select **File → Add Package Dependencies** and enter the repository URL, or add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/chenlin1037/WhiteNoiseSDK.git", from: "1.0.3")
]
```

---

## Quick Start

### 1. Info.plist Configuration

Add the following inside your `Info.plist`'s top-level `<dict>`:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

### 2. Basic Playback

```swift
import WhiteNoiseSDK

// Use the global singleton (default configuration)
let engine = WhiteNoiseEngine.shared

// Play a single sound
Task {
    do {
        try await engine.play(
            url: URL(string: "https://example.com/rain.mp3")!,
            id: "rain",
            volume: 0.8,
            name: "Rain"
        )
    } catch let error as EngineError {
        print("Playback failed: \(error)")
    }
}
```

### 3. Custom Configuration

```swift
let config = WhiteNoiseEngine.Configuration(
    maxConcurrentTracks: 4,      // Maximum 4 tracks
    artistName: "MyApp",          // Now Playing artist name
    nowPlayingEnabled: true,      // Enable lock screen controls
    maxDiskCacheBytes: 200 * 1024 * 1024  // 200 MB cache
)
let engine = WhiteNoiseEngine(configuration: config)
```

### 4. Batch Mix Playback

```swift
let items: [(soundID: String, volume: Float, url: URL, name: String)] = [
    ("rain",  0.7, rainURL,  "Rain"),
    ("wind",  0.5, windURL,  "Wind"),
    ("fire",  0.6, fireURL,  "Campfire"),
]

Task {
    try await engine.applyMix(items: items, mixName: "Forest Night Rain")
}
```

### 5. Volume Control

```swift
// Single track fade (default 0.3 seconds)
engine.setVolume(0.5, for: "rain")

// Custom fade duration
engine.setVolume(0.3, for: "wind", fade: 1.0)

// Master volume
engine.setMasterVolume(0.8)
```

### 6. Removing Tracks

```swift
// Fade out then remove (default 1 second)
engine.remove(id: "rain")

// Custom fade out duration
engine.remove(id: "wind", fadeDuration: 2.0)
```

### 7. Global Controls

```swift
engine.pauseAll()
engine.resumeAll()
engine.stopAll()
```

### 8. SwiftUI Integration

```swift
struct PlayerView: View {
    @StateObject private var engine = WhiteNoiseEngine.shared

    var body: some View {
        VStack {
            Text(engine.state == .playing ? "Playing" : "Stopped")

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

## Error Handling

`EngineError` is a public enum surfaced by `async throws` APIs such as `play(...)` and `applyMix(...)`. Common cases include:

- `.invalidURL` — the provided audio URL could not be resolved
- `.maxTracksExceeded` — the configured `maxConcurrentTracks` limit was reached
- `.networkFailure(Error)` — the download failed
- `.cacheError(Error)` — disk cache read/write failure

Wrap calls in `do/catch` to handle these gracefully in your UI.

---

## Architecture

```
WhiteNoiseSDK/
├── Sources/WhiteNoiseSDK/
│   ├── WhiteNoiseSDK.swift       # Public entry point & TypeAliases
│   ├── WhiteNoiseEngine.swift    # Core engine (public)
│   ├── EngineTypes.swift         # EngineState / EngineError (public)
│   ├── AudioTrack.swift          # Track model (public)
│   ├── NowPlayingManager.swift   # Lock screen integration (internal)
│   ├── AudioSessionManager.swift # AVAudioSession wrapper (internal)
│   ├── AudioCache.swift          # Disk cache (internal)
│   └── NetworkLoader.swift       # Network downloader (internal)
└── Tests/WhiteNoiseSDKTests/
    └── WhiteNoiseSDKTests.swift
```

### Access Control Principles

| Type | Access Level | Description |
|------|----------|------|
| `WhiteNoiseEngine` | `public` | Used directly by host project |
| `AudioTrack` | `public` | SwiftUI binding |
| `EngineState` | `public` | State enum |
| `EngineError` | `public` | Error handling |
| `NowPlayingManager` | `internal` | Implementation detail |
| `AudioCache` | `internal` | Implementation detail |
| `NetworkLoader` | `internal` | Implementation detail |
| `AudioSessionManager` | `internal` | Implementation detail |

---

## Migration from Original Project

| Original Code | SDK Code |
|----------|----------|
| `WhiteNoiseEngine.shared` | Unchanged |
| `NowPlayingManager.shared.updateNowPlaying(...)` | Handled automatically by the engine, no manual call needed |
| `AudioTrack.applyUIVolume(_:)` | For SDK internal use only, not callable externally |
| Cache directory `WhiteNoiseAudio` | Changed to `WhiteNoiseSDKAudio` (to avoid conflicts with old cache) |

---

## Contributing

Issues and pull requests are welcome. Please open an issue first to discuss significant changes.

## License

Specify your license here (e.g., MIT, Apache 2.0).
```

The biggest gaps were the missing License section (important for any public SPM package) and lack of error-handling documentation given `EngineError` is part of the public API surface. The rest are minor polish.