//
//  ChunkDownloader.swift
//  YunX
//
//  分片下载器：Range 探测、断点续传写盘、严格截断、慢连接抢占中断、单流回退、边合并边删分片。
//

import Foundation

public enum ChunkOutcome: Sendable, Equatable {
    case ok
    case rangeIgnored
    case preempted
    case failed(String)
}

public final class PreemptSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false
    private var onCancel: (() -> Void)?

    public init() {}

    public var isPreempted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }

    public func bindCancel(_ action: @escaping () -> Void) {
        lock.lock()
        onCancel = action
        let already = flagged
        lock.unlock()
        if already { action() }
    }

    public func trigger() {
        lock.lock()
        flagged = true
        let action = onCancel
        lock.unlock()
        action?()
    }

    public func reset() {
        lock.lock()
        flagged = false
        onCancel = nil
        lock.unlock()
    }
}

public final class ChunkDownloader: Sendable {
    public static let readBufferSize = 64 * 1024
    private static let chunkRetries = 3

    private let session: URLSession

    public init(session: URLSession = HTTPClient.shared.downloadSession) {
        self.session = session
    }

    // MARK: - 文件大小探测

    public func probeTotalSize(url urlString: String, headers: [String: String]) async -> Int64? {
        if let ranged = await probeSize(urlString: urlString, headers: headers, withRange: true) {
            return ranged
        }
        return await probeSize(urlString: urlString, headers: headers, withRange: false)
    }

    private func probeSize(urlString: String, headers: [String: String], withRange: Bool) async -> Int64? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        if withRange {
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        }
        for (k, v) in headers where !v.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return nil }
            let ct = http.value(forHTTPHeaderField: "Content-Type")
            if HttpRangePolicy.isHtmlResponse(contentType: ct) { return nil }
            guard (200..<300).contains(http.statusCode) else { return nil }
            if withRange {
                guard http.statusCode == 206,
                      let cr = HttpRangePolicy.parse(http.value(forHTTPHeaderField: "Content-Range")),
                      cr.start == 0, cr.end == 0 else {
                    return nil
                }
                return cr.total
            } else {
                if let lenStr = http.value(forHTTPHeaderField: "Content-Length"),
                   let len = Int64(lenStr), len > 0 {
                    return len
                }
                return http.expectedContentLength > 0 ? http.expectedContentLength : nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - 单分片 Range 下载（含断点续传 + 慢连接抢占无缝重连）

    public func downloadChunk(
        url urlString: String,
        range: ByteRange,
        partURL: URL,
        headers: [String: String],
        preemptSignal: PreemptSignal? = nil,
        onBytes: @Sendable (Int64) async -> Void
    ) async throws -> ChunkOutcome {
        let maxAttempts = Self.chunkRetries + 3
        var ioFailures = 0

        for attempt in 0..<maxAttempts {
            if Task.isCancelled { throw CancellationError() }
            let existing = Self.fileSize(at: partURL)
            if existing >= range.length {
                return .ok
            }
            let from = range.start + existing
            let outcome = try await singleRangeAttempt(
                urlString: urlString,
                from: from,
                end: range.end,
                existing: existing,
                partURL: partURL,
                headers: headers,
                preemptSignal: preemptSignal,
                onBytes: onBytes
            )
            switch outcome {
            case .ok:
                return .ok
            case .rangeIgnored:
                return .rangeIgnored
            case .preempted:
                // 慢连接抢占：保留已写字节、重置标志、零退避立即换新连接续传
                preemptSignal?.reset()
                continue
            case .failed(let reason):
                ioFailures += 1
                if ioFailures > Self.chunkRetries || attempt == maxAttempts - 1 {
                    return .failed(reason)
                }
                let backoffNs = UInt64(min(3000, 500 * ioFailures)) * 1_000_000
                try await Task.sleep(nanoseconds: backoffNs)
            }
        }
        return .failed("分片重试次数已耗尽")
    }

    private func singleRangeAttempt(
        urlString: String,
        from: Int64,
        end: Int64,
        existing: Int64,
        partURL: URL,
        headers: [String: String],
        preemptSignal: PreemptSignal?,
        onBytes: @Sendable (Int64) async -> Void
    ) async throws -> ChunkOutcome {
        guard let url = URL(string: urlString) else {
            return .failed("无效的下载地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("bytes=\(from)-\(end)", forHTTPHeaderField: "Range")
        for (k, v) in headers where !v.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (asyncBytes, response) = try await session.bytes(for: request)
            preemptSignal?.bindCancel {
                asyncBytes.task.cancel()
            }
            defer { asyncBytes.task.cancel() }

            guard let http = response as? HTTPURLResponse else {
                return .failed("非 HTTP 响应")
            }
            if HttpRangePolicy.isHtmlResponse(contentType: http.value(forHTTPHeaderField: "Content-Type")) {
                return .failed("直链返回了网页（可能已过期或触发防盗链）")
            }
            if http.statusCode == 200 {
                return .rangeIgnored
            }
            guard http.statusCode == 206 else {
                return .failed("HTTP \(http.statusCode)")
            }
            guard HttpRangePolicy.matches(http.value(forHTTPHeaderField: "Content-Range"), requestedStart: from, requestedEnd: end) else {
                return .failed("服务端返回的 Content-Range 与请求不匹配")
            }

            let expected = end - from + 1
            let written = try await streamWrite(
                bytes: asyncBytes,
                to: partURL,
                seekOffset: existing,
                expectedBytes: expected,
                preemptSignal: preemptSignal,
                onBytes: onBytes
            )
            if preemptSignal?.isPreempted == true {
                return .preempted
            }
            if written != expected {
                return .failed("分片写入不完整（\(written)/\(expected)）")
            }
            return .ok
        } catch is CancellationError {
            if preemptSignal?.isPreempted == true {
                return .preempted
            }
            throw CancellationError()
        } catch {
            if preemptSignal?.isPreempted == true {
                return .preempted
            }
            if Task.isCancelled { throw CancellationError() }
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 单流整文件回退下载

    public func downloadFull(
        url urlString: String,
        targetURL: URL,
        headers: [String: String],
        expectedTotal: Int64,
        onBytes: @Sendable (Int64) async -> Void
    ) async throws {
        guard let url = URL(string: urlString) else {
            throw HTTPClientError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for (k, v) in headers where !v.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // 完整 GET 必须从 0 开始，避免与旧前缀拼接损坏
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }

        let (asyncBytes, response) = try await session.bytes(for: request)
        defer { asyncBytes.task.cancel() }

        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse
        }
        if HttpRangePolicy.isHtmlResponse(contentType: http.value(forHTTPHeaderField: "Content-Type")) {
            throw HTTPClientError.httpError(http.statusCode, "下载链接已过期或返回了错误页面")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPClientError.httpError(http.statusCode, "下载失败（HTTP \(http.statusCode)）")
        }

        let written = try await streamWrite(
            bytes: asyncBytes,
            to: targetURL,
            seekOffset: 0,
            expectedBytes: expectedTotal > 0 ? expectedTotal : -1,
            preemptSignal: nil,
            onBytes: onBytes
        )
        if expectedTotal > 0 && written < expectedTotal {
            throw HTTPClientError.httpError(http.statusCode, "文件下载不完整（\(written)/\(expectedTotal)）")
        }
    }

    // MARK: - 流式写入与边合并边删分片

    private func streamWrite(
        bytes: URLSession.AsyncBytes,
        to fileURL: URL,
        seekOffset: Int64,
        expectedBytes: Int64,
        preemptSignal: PreemptSignal?,
        onBytes: @Sendable (Int64) async -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, seekOffset)))

        var buffer = [UInt8]()
        buffer.reserveCapacity(Self.readBufferSize)
        var written: Int64 = 0

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            if preemptSignal?.isPreempted == true { break }
            buffer.append(byte)
            if buffer.count >= Self.readBufferSize || (expectedBytes > 0 && written + Int64(buffer.count) >= expectedBytes) {
                let allow = expectedBytes > 0 ? Int(min(Int64(buffer.count), expectedBytes - written)) : buffer.count
                if allow > 0 {
                    try handle.write(contentsOf: buffer[0..<allow])
                    written += Int64(allow)
                    await onBytes(Int64(allow))
                }
                buffer.removeAll(keepingCapacity: true)
                if expectedBytes > 0 && written >= expectedBytes { break }
            }
        }

        if !buffer.isEmpty && (expectedBytes < 0 || written < expectedBytes) {
            let allow = expectedBytes > 0 ? Int(min(Int64(buffer.count), expectedBytes - written)) : buffer.count
            if allow > 0 {
                try handle.write(contentsOf: buffer[0..<allow])
                written += Int64(allow)
                await onBytes(Int64(allow))
            }
        }
        return written
    }

    /// 边合并边删除分片文件，避免大文件峰值占用 2~3 倍磁盘空间
    public func mergeChunks(
        partFiles: [URL],
        to destinationURL: URL,
        totalBytes: Int64,
        onProgress: @Sendable (Int) async -> Void
    ) async throws -> Int64 {
        let fm = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        fm.createFile(atPath: destinationURL.path, contents: nil)

        let outHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? outHandle.close() }

        var mergedTotal: Int64 = 0
        var lastPercent = -1

        for part in partFiles {
            if Task.isCancelled { throw CancellationError() }
            let inHandle = try FileHandle(forReadingFrom: part)
            while true {
                if Task.isCancelled {
                    try? inHandle.close()
                    throw CancellationError()
                }
                let data = try inHandle.read(upToCount: Self.readBufferSize) ?? Data()
                if data.isEmpty { break }
                try outHandle.write(contentsOf: data)
                mergedTotal += Int64(data.count)
            }
            try? inHandle.close()
            // 当前分片已完整落盘，立即删除释放磁盘空间
            try? fm.removeItem(at: part)

            if totalBytes > 0 {
                let pct = min(100, Int((mergedTotal * 100) / totalBytes))
                if pct != lastPercent {
                    lastPercent = pct
                    await onProgress(pct)
                }
            }
        }
        await onProgress(100)
        return mergedTotal
    }

    public static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }
}
