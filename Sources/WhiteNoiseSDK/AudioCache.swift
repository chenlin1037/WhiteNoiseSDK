//
//  AudioCache.swift
//  WhiteNoiseSDK
//
//  internal —— 不暴露给宿主项目
//

import CryptoKit
import Foundation

actor AudioCache {

    private let directory: URL
    private let maxDiskBytes: Int

    init(maxDiskBytes: Int = 500 * 1024 * 1024) {
        self.maxDiskBytes = maxDiskBytes
        let base  = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("WhiteNoiseSDKAudio", isDirectory: true)
    }

    // MARK: - API（由 NetworkLoader 调用）

    func localURL(for remoteURL: URL) -> URL? {
        let dest = destinationURL(for: remoteURL)
        guard FileManager.default.fileExists(atPath: dest.path) else { return nil }
        touchModificationDate(dest)
        return dest
    }

    func destinationURL(for remoteURL: URL) -> URL {
        let hash = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(hash + ".caf")
    }

    func prepareDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func evictIfNeeded() throws {
        let fm           = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]

        let allFiles = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: .skipsHiddenFiles
        )

        // 清理孤立临时文件
        let cafNames = Set(
            allFiles.filter { $0.pathExtension == "caf" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        for file in allFiles where file.pathExtension == "download" || file.pathExtension == "etag" {
            let base = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            if !cafNames.contains(base) { try? fm.removeItem(at: file) }
        }

        // LRU 淘汰
        let cafFiles = allFiles
            .filter { $0.pathExtension == "caf" }
            .compactMap { url -> (url: URL, size: Int, date: Date)? in
                let v = try? url.resourceValues(forKeys: resourceKeys)
                guard let size = v?.fileSize, let date = v?.contentModificationDate else { return nil }
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

    func clearAll() throws {
        try FileManager.default.removeItem(at: directory)
        try prepareDirectoryIfNeeded()
    }

    // MARK: - Private

    private func touchModificationDate(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }
}
