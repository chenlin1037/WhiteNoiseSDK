//
//  NetworkLoader.swift
//  WhiteNoiseSDK
//
//  internal —— 不暴露给宿主项目
//

import Foundation

actor NetworkLoader {

    /// 先查缓存，再下载到磁盘
    func fetch(url: URL, cache: AudioCache, isCacheHit: @escaping (Bool) -> Void) async throws -> URL {
        try await cache.prepareDirectoryIfNeeded()

        if let cached = await cache.localURL(for: url) {
            isCacheHit(true)
            return cached
        }

        isCacheHit(false)
        let destination = await cache.destinationURL(for: url)
        
        // ⚠️ 修复：添加重试机制（最多3次）
        var lastError: Error?
        for attempt in 1...3 {
            do {
                try await download(from: url, to: destination)
                try await cache.evictIfNeeded()
                return destination
            } catch {
                lastError = error
                wn_log(.warning, "下载失败 (尝试 \(attempt)/3): \(error)")
                
                // 清理失败的临时文件
                try? FileManager.default.removeItem(at: destination)
                
                // 如果不是最后一次尝试，等待后重试
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(Double(attempt) * 0.5 * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? URLError(.unknown)
    }

    private func download(from url: URL, to destination: URL) async throws {
        // ⚠️ 修复：添加超时控制（30秒）
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        
        let (tmpURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw URLError(.badServerResponse)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }
}
