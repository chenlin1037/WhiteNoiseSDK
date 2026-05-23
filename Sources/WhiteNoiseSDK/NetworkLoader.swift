//
//  NetworkLoader.swift
//  WhiteNoiseSDK
//

import Foundation

public actor NetworkLoader {

    public init() {}

    public func fetch(url: URL, cache: AudioCache) async throws -> URL {
        try await cache.prepareDirectoryIfNeeded()
        if let cached = await cache.localURL(for: url) { return cached }
        let destination = await cache.destinationURL(for: url)
        try await download(from: url, to: destination)
        try await cache.evictIfNeeded()
        return destination
    }

    private func download(from url: URL, to destination: URL) async throws {
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }
}
