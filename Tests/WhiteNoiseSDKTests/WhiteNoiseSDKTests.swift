//
//  WhiteNoiseSDKTests.swift
//  WhiteNoiseSDKTests
//

import XCTest
@testable import WhiteNoiseSDK

final class WhiteNoiseSDKTests: XCTestCase {

    // MARK: - Configuration

    func testDefaultConfiguration() {
        let config = WhiteNoiseEngine.Configuration()
        XCTAssertEqual(config.maxConcurrentTracks, 6)
        XCTAssertEqual(config.artistName, "WhiteNoiseSDK")
        XCTAssertTrue(config.nowPlayingEnabled)
        XCTAssertEqual(config.maxDiskCacheBytes, 500 * 1024 * 1024)
    }

    func testCustomConfiguration() {
        let config = WhiteNoiseEngine.Configuration(
            maxConcurrentTracks: 3,
            artistName: "MyApp",
            nowPlayingEnabled: false,
            maxDiskCacheBytes: 100 * 1024 * 1024
        )
        XCTAssertEqual(config.maxConcurrentTracks, 3)
        XCTAssertEqual(config.artistName, "MyApp")
        XCTAssertFalse(config.nowPlayingEnabled)
        XCTAssertEqual(config.maxDiskCacheBytes, 100 * 1024 * 1024)
    }

    // MARK: - Engine Init

    func testSharedInstanceIsSingleton() {
        let a = WhiteNoiseEngine.shared
        let b = WhiteNoiseEngine.shared
        XCTAssertTrue(a === b)
    }

    func testIndependentInstancesAreDistinct() {
        let a = WhiteNoiseEngine()
        let b = WhiteNoiseEngine()
        XCTAssertFalse(a === b)
    }

    // MARK: - EngineError

    func testTooManyTracksError() {
        let error = EngineError.tooManyTracks(limit: 6)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("6"))
    }

    func testEngineDeallocatedError() {
        let error = EngineError.engineDeallocated
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - AudioTrack

    @MainActor
    func testAudioTrackDisplayName() {
        let player = AVAudioPlayerNode()
        let track  = AudioTrack(id: "rain", player: player, volume: 0.8, displayName: "Rain")
        XCTAssertEqual(track.displayName, "Rain")
        XCTAssertEqual(track.volume, 0.8, accuracy: 0.001)
    }

    @MainActor
    func testAudioTrackDefaultDisplayNameFallsBackToID() {
        let player = AVAudioPlayerNode()
        let track  = AudioTrack(id: "rain", player: player)
        XCTAssertEqual(track.displayName, "rain")
    }

    @MainActor
    func testApplyUIVolume() {
        let player = AVAudioPlayerNode()
        let track  = AudioTrack(id: "ocean", player: player, volume: 1.0)
        track.applyUIVolume(0.5)
        XCTAssertEqual(track.volume, 0.5, accuracy: 0.001)
    }

    // MARK: - EngineState

    func testEngineStateEquality() {
        XCTAssertEqual(EngineState.idle, .idle)
        XCTAssertNotEqual(EngineState.playing, .paused)
    }

    // MARK: - TypeAliases

    func testTypeAliasesResolve() {
        let _: WNEngine.Type       = WNEngine.self
        let _: WNEngineState.Type  = WNEngineState.self
        let _: WNEngineError.Type  = WNEngineError.self
        let _: WNAudioTrack.Type   = WNAudioTrack.self
        let _: WNConfiguration.Type = WNConfiguration.self
    }
}
