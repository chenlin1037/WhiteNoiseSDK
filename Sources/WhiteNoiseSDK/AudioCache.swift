//
//  AudioCache.swift
//  WhiteNoiseSDK
//

import CryptoKit
import Foundation

public actor AudioCache {

    private let directory: URL
    private let maxDiskBytes: Int

    public init(maxDiskBytes: Int = 500 * 1024 * 1024) {
        self.maxDiskBytes = maxDiskBytes
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("WhiteNoiseAudio", isDirectory: true)
    }

    public func localURL(for remoteURL: URL) -> URL? {
        let dest = destinationURL(for: remoteURL)
        guard FileManager.default.fileExists(atPath: dest.path) else { return nil }
        touchModificationDate(dest)
        return dest
    }

    public func destinationURL(for remoteURL: URL) -> URL {
        let hash = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(hash + ".caf")
    }

    public func prepareDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func evictIfNeeded() throws {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .nameKey]
        let allFiles = try fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(resourceKeys), options: .skipsHiddenFiles
        )
        let cafNames = Set(allFiles.filter { $0.pathExtension == "caf" }
            .map { $0.deletingPathExtension().lastPathComponent })
        for file in allFiles where file.pathExtension == "download" || file.pathExtension == "etag" {
            let baseName = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            if !cafNames.contains(baseName) { try? fm.removeItem(at: file) }
        }
        let cafFiles = allFiles.filter { $0.pathExtension == "caf" }
            .compactMap { url -> (url: URL, size: Int, date: Date)? in
                let values = try? url.resourceValues(forKeys: resourceKeys)
                guard let size = values?.fileSize, let date = values?.contentModificationDate else { return nil }
                return (url, size, date)
            }
            .sorted { $0.date > $1.date }
        var totalBytes = cafFiles.reduce(0) { $0 + $1.size }
        for entry in cafFiles.reversed() {
            guard totalBytes > maxDiskBytes else { break }
            try? fm.removeItem(at: entry.url)
            try? fm.removeItem(at: entry.url.appendingPathExtension("download"))
            try? fm.removeItem(at: entry.url.appendingPathExtension("etag"))
            totalBytes -= entry.size
        }
    }

    public func clearAll() throws {
        try FileManager.default.removeItem(at: directory)
        try prepareDirectoryIfNeeded()
    }

    private func touchModificationDate(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
