//
//  DownloadEngineTests.swift
//  YunXTests
//
//  下载引擎核心算法单元测试：HttpRangePolicy、ChunkPlanner（70/30 主池弹性区）与 ElasticAllocator 尾部收缩。
//

import XCTest
@testable import YunX

final class DownloadEngineTests: XCTestCase {
    func testHttpRangePolicyParseAndMatch() {
        let parsed = HttpRangePolicy.parse("bytes 0-0/1048576")
        XCTAssertEqual(parsed?.start, 0)
        XCTAssertEqual(parsed?.end, 0)
        XCTAssertEqual(parsed?.total, 1_048_576)

        XCTAssertTrue(HttpRangePolicy.matches("bytes 100-199/500", requestedStart: 100, requestedEnd: 199))
        XCTAssertFalse(HttpRangePolicy.matches("bytes 0-199/500", requestedStart: 100, requestedEnd: 199))
        XCTAssertNil(HttpRangePolicy.parse("bytes 200-100/500"))
        XCTAssertNil(HttpRangePolicy.parse("bytes 0-500/500"))
    }

    func testChunkPlannerSplitAndSignature() {
        let total: Int64 = 100 * 1024 * 1024 // 100 MB
        let plan = ChunkPlanner.makePlan(totalSize: total, threads: 16)
        XCTAssertGreaterThan(plan.totalChunks, 16)
        XCTAssertLessThanOrEqual(plan.totalChunks, ChunkPlanner.maxChunksHardCap)
        XCTAssertEqual(plan.mainRanges.count, plan.mainChunkCount)
        XCTAssertGreaterThan(plan.elasticStart, 0)
        XCTAssertLessThan(plan.elasticStart, total)
        XCTAssertEqual(plan.mainRanges.first?.start, 0)
        XCTAssertEqual(plan.mainRanges.last!.end + 1, plan.elasticStart)
        XCTAssertTrue(plan.signature.contains("total=\(total)"))
    }

    func testElasticAllocatorCoversFullTailWithoutGaps() {
        let total: Int64 = 10 * 1024 * 1024
        let elasticStart: Int64 = 7 * 1024 * 1024
        let allocator = ElasticAllocator(total: total, elasticStart: elasticStart, workers: 8, chunkSize: 512 * 1024)
        allocator.updateSpeed(4 * 1024 * 1024)

        var ranges: [ByteRange] = []
        while let r = allocator.take() {
            ranges.append(r)
        }
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertEqual(ranges.first?.start, elasticStart)
        XCTAssertEqual(ranges.last?.end, total - 1)
        for i in 1..<ranges.count {
            XCTAssertEqual(ranges[i - 1].end + 1, ranges[i].start)
        }
    }
}
