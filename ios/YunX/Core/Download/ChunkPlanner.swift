//
//  ChunkPlanner.swift
//  YunX
//
//  任务池 + 弹性区（IDM 式）分片规划器与尾部收缩分配器。
//  严格对齐 Android DownloadManager §5.1 / §5.2 算法。
//

import Foundation

public struct ByteRange: Equatable, Hashable, Sendable {
    public let start: Int64
    public let end: Int64

    public var length: Int64 { max(0, end - start + 1) }

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
}

public struct ChunkPlan: Equatable, Sendable {
    public let totalSize: Int64
    public let totalChunks: Int
    public let mainChunkCount: Int
    public let mainChunkSize: Int64
    public let mainRanges: [ByteRange]
    public let elasticStart: Int64

    /// 持久化签名串（用于断点续传核验：线程档位或文件大小变动时自动清片重下）
    public var signature: String {
        "chunks=\(totalChunks) total=\(totalSize) main=\(mainChunkCount)"
    }
}

public enum ChunkPlanner {
    public static let minChunkBytes: Int64 = 256 * 1024
    public static let maxChunksHardCap = 512

    /// 按文件大小与目标线程数计算总分片数（每线程平均 8 片盈余，单片不小于 256KB，上限 512）
    public static func chunkCount(for total: Int64, threads: Int) -> Int {
        guard total > 0 else { return 1 }
        let bySize: Int
        switch total {
        case ..<(5 * 1024 * 1024): bySize = 1
        case ..<(50 * 1024 * 1024): bySize = 8
        case ..<(500 * 1024 * 1024): bySize = 32
        default: bySize = 64
        }
        let safeThreads = max(1, threads)
        let want = max(bySize, safeThreads * 8)
        let byMinSize = max(1, Int(total / minChunkBytes))
        return max(1, min(want, min(byMinSize, maxChunksHardCap)))
    }

    /// 划分 70% 主池 + 30% 弹性区
    public static func makePlan(totalSize: Int64, threads: Int) -> ChunkPlan {
        let chunks = chunkCount(for: totalSize, threads: threads)
        guard chunks > 1, totalSize > minChunkBytes else {
            return ChunkPlan(
                totalSize: totalSize,
                totalChunks: 1,
                mainChunkCount: 1,
                mainChunkSize: totalSize,
                mainRanges: [ByteRange(start: 0, end: max(0, totalSize - 1))],
                elasticStart: totalSize
            )
        }

        let chunkSize = (totalSize + Int64(chunks) - 1) / Int64(chunks)
        let mainCount = max(1, min(chunks, Int(Double(chunks) * 0.7)))

        var mainRanges: [ByteRange] = []
        mainRanges.reserveCapacity(mainCount)
        var cursor: Int64 = 0
        for i in 0..<mainCount {
            if cursor >= totalSize { break }
            let isLastEntire = (i == chunks - 1)
            let end = isLastEntire ? (totalSize - 1) : min(cursor + chunkSize - 1, totalSize - 1)
            mainRanges.append(ByteRange(start: cursor, end: end))
            cursor = end + 1
        }

        return ChunkPlan(
            totalSize: totalSize,
            totalChunks: chunks,
            mainChunkCount: mainRanges.count,
            mainChunkSize: chunkSize,
            mainRanges: mainRanges,
            elasticStart: min(cursor, totalSize)
        )
    }
}

/// 弹性区动态分片分配器：按字节顺序发块（保持连接友好）+ 速度自适应 + 尾部收缩消除长尾拖速
public final class ElasticAllocator: @unchecked Sendable {
    public static let minElasticBlock: Int64 = 256 * 1024
    public static let maxElasticBlock: Int64 = 4 * 1024 * 1024
    public static let minTailBlock: Int64 = 64 * 1024
    public static let targetSeconds: Int64 = 5

    private let lock = NSLock()
    private let total: Int64
    private let workers: Int
    private let chunkSize: Int64
    private var nextStart: Int64
    private var _recentSpeedBps: Int64 = 0

    public init(total: Int64, elasticStart: Int64, workers: Int, chunkSize: Int64) {
        self.total = total
        self.nextStart = elasticStart
        self.workers = max(1, workers)
        self.chunkSize = chunkSize
    }

    public func updateSpeed(_ speedBps: Int64) {
        lock.lock()
        _recentSpeedBps = max(0, speedBps)
        lock.unlock()
    }

    /// 断点续传时跳过已完成的连续前缀
    public func skipTo(_ offset: Int64) {
        lock.lock()
        if offset > nextStart {
            nextStart = min(offset, total)
        }
        lock.unlock()
    }

    /// 领取下一个弹性块；无剩余返回 nil
    public func take() -> ByteRange? {
        lock.lock()
        defer { lock.unlock() }
        guard nextStart < total else { return nil }
        let remaining = total - nextStart
        let base = baseBlockSizeLocked()
        let block: Int64
        if remaining <= Int64(workers) * base {
            let sliced = remaining / Int64(workers)
            block = min(max(sliced, Self.minTailBlock), base)
        } else {
            block = base
        }
        let start = nextStart
        let end = min(start + block - 1, total - 1)
        nextStart = end + 1
        return ByteRange(start: start, end: end)
    }

    private func baseBlockSizeLocked() -> Int64 {
        let perWorker = _recentSpeedBps / Int64(workers)
        if perWorker <= 0 {
            return min(max(chunkSize, Self.minElasticBlock), Self.maxElasticBlock)
        }
        return min(max(perWorker * Self.targetSeconds, Self.minElasticBlock), Self.maxElasticBlock)
    }
}
