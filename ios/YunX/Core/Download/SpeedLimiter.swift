//
//  SpeedLimiter.swift
//  YunX
//
//  全局令牌桶限速器与异步并发信号量。
//

import Foundation

/// 全局限速器：所有下载任务共享配额，limitBytesPerSec <= 0 时不限速
public actor SpeedLimiter {
    private var tokens: Double = 0
    private var lastRefill: Date = Date()

    public init() {}

    public func consume(bytes: Int64, limitBytesPerSec: Int64) async {
        guard limitBytesPerSec > 0, bytes > 0 else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        lastRefill = now
        let rate = Double(limitBytesPerSec)
        tokens = min(rate, tokens + elapsed * rate)
        tokens -= Double(bytes)
        if tokens < 0 {
            let waitSec = min(1.5, (-tokens) / rate)
            if waitSec > 0.005 {
                try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
            }
        }
    }
}

/// Swift Concurrency 异步信号量（用于跨任务全局在飞分片配额限制）
public actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init(value: Int) {
        self.permits = max(1, value)
    }

    public func acquire() async throws {
        if Task.isCancelled { throw CancellationError() }
        if permits > 0 {
            permits -= 1
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }
}
