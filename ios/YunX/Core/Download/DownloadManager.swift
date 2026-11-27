//
//  DownloadManager.swift
//  YunX
//
//  多线程弹性分片下载管理器：
//  - 任务持久化 + 500ms 落盘节流（高频速度走内存 stats）；
//  - 70% 主池 + 30% ElasticAllocator 弹性区 + 5s 慢连接看门狗抢占；
//  - 迅雷自动限 8 线程、Range 连续降级自动回退单流；
//  - 成果直接落盘至 Documents/YunXDownloads（iOS 系统「文件」App 零权限可见）。
//

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

private final class InflightTracker: @unchecked Sendable {
    let key: String
    let start: Int64
    let size: Int64
    let signal = PreemptSignal()
    let startedAt = Date()

    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var lastBytes: Int64 = 0
    private var lastSampleAt: Date
    private var _lastBps: Int64 = 0
    private var _preemptCount = 0
    private var _lastPreemptAt: Date?

    init(key: String, start: Int64, size: Int64) {
        self.key = key
        self.start = start
        self.size = size
        self.lastSampleAt = startedAt
    }

    func addBytes(_ delta: Int64) {
        lock.lock()
        bytes += delta
        lock.unlock()
    }

    func sample(now: Date) -> (bps: Int64, received: Int64, remaining: Int64, ageSec: TimeInterval, preemptCount: Int, cooldownOk: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let dt = max(0.05, now.timeIntervalSince(lastSampleAt))
        let delta = max(0, bytes - lastBytes)
        _lastBps = Int64(Double(delta) / dt)
        lastBytes = bytes
        lastSampleAt = now
        let age = now.timeIntervalSince(startedAt)
        let cooldownOk = _lastPreemptAt.map { now.timeIntervalSince($0) >= 10.0 } ?? true
        return (_lastBps, bytes, max(0, size - bytes), age, _preemptCount, cooldownOk)
    }

    func markPreempted(now: Date) {
        lock.lock()
        _preemptCount += 1
        _lastPreemptAt = now
        lock.unlock()
        signal.trigger()
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ initial: Int64 = 0) { self.value = initial }

    @discardableResult
    func add(_ delta: Int64) -> Int64 {
        lock.lock()
        value += delta
        let res = value
        lock.unlock()
        return res
    }

    func set(_ newValue: Int64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int64 {
        lock.lock()
        let res = value
        lock.unlock()
        return res
    }
}

private final class MainChunkQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(index: Int, range: ByteRange)]

    init(items: [(index: Int, range: ByteRange)]) {
        self.items = items
    }

    func popFirst() -> (index: Int, range: ByteRange)? {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

private final class InflightRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: InflightTracker] = [:]

    func insert(_ tracker: InflightTracker, forKey key: String) {
        lock.lock()
        map[key] = tracker
        lock.unlock()
    }

    func remove(forKey key: String) {
        lock.lock()
        map.removeValue(forKey: key)
        lock.unlock()
    }

    func snapshot() -> [InflightTracker] {
        lock.lock()
        defer { lock.unlock() }
        return Array(map.values)
    }
}

@MainActor
@Observable
public final class DownloadManager {
    public private(set) var tasks: [DownloadTask] = []
    public private(set) var stats: [UUID: DownloadStats] = [:]

    /// 是否有正在运行的下载任务（供 UI 与防息屏监听使用）
    public var hasActiveDownloads: Bool {
        tasks.contains { $0.status == .downloading }
    }

    /// 全局总实时下载速度（字节/秒）
    public var totalSpeedBytesPerSec: Int64 {
        stats.values.reduce(0) { $0 + $1.speedBytesPerSec }
    }

    /// 完成回调（例如通知夸克清理临时转存子目录）
    public var onTaskCompleted: ((UUID) -> Void)?

    private let settings: SettingsStore
    private let downloader: ChunkDownloader
    private let speedLimiter = SpeedLimiter()
    private let inflightSemaphore = AsyncSemaphore(value: 64)

    private var runningJobs: [UUID: Task<Void, Never>] = [:]
    private var completionCallbacks: [UUID: @Sendable () async -> Void] = [:]

    private let tasksFileURL: URL
    public let downloadsRootURL: URL
    private let tempRootURL: URL

    public init(
        settings: SettingsStore,
        downloader: ChunkDownloader = ChunkDownloader()
    ) {
        self.settings = settings
        self.downloader = downloader

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YunX", isDirectory: true)
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YunXDownloads", isDirectory: true)
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("YunXDownloadTmp", isDirectory: true)

        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)

        self.tasksFileURL = appSupport.appendingPathComponent("download_tasks.json")
        self.downloadsRootURL = docs
        self.tempRootURL = caches

        loadTasks()
        markInterruptedAsPaused()
    }

    // MARK: - 公开控制接口

    @discardableResult
    public func enqueue(
        url: String,
        fileName: String,
        headers: [String: String] = [:],
        size: Int64 = 0,
        platform: DownloadPlatform = .generic,
        onFinishCleanup: (@Sendable () async -> Void)? = nil
    ) -> DownloadTask {
        let sanitized = sanitizeRelativePath(fileName.isEmpty ? inferFileName(from: url) : fileName)
        let task = DownloadTask(
            fileName: sanitized,
            url: url,
            headers: headers,
            platform: platform,
            totalSize: max(0, size),
            status: .pending
        )
        tasks.insert(task, at: 0)
        if let onFinishCleanup {
            completionCallbacks[task.id] = onFinishCleanup
        }
        persistTasks()
        schedulePendingTasks()
        return task
    }

    public func resume(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        guard tasks[idx].status == .paused || tasks[idx].status == .failed else { return }
        tasks[idx].status = .pending
        tasks[idx].errorMessage = nil
        persistTasks()
        schedulePendingTasks()
    }

    public func pause(taskId: UUID) {
        runningJobs[taskId]?.cancel()
        runningJobs.removeValue(forKey: taskId)
        stats.removeValue(forKey: taskId)
        if let idx = tasks.firstIndex(where: { $0.id == taskId }),
           tasks[idx].status == .downloading || tasks[idx].status == .pending {
            tasks[idx].status = .paused
            let diskBytes = Self.diskTempBytes(in: tempDir(for: taskId))
            if diskBytes > 0 {
                let total = tasks[idx].totalSize
                tasks[idx].downloadedSize = total > 0 ? min(diskBytes, total) : diskBytes
            }
            persistTasks()
        }
        updateIdleTimer()
        schedulePendingTasks()
    }

    public func pauseAllForBackground() {
        let activeIds = tasks.filter { $0.status == .downloading }.map(\.id)
        for id in activeIds {
            pause(taskId: id)
        }
    }

    public func remove(taskId: UUID, deleteLocalFile: Bool = true) {
        runningJobs[taskId]?.cancel()
        runningJobs.removeValue(forKey: taskId)
        stats.removeValue(forKey: taskId)
        if let cleanup = completionCallbacks.removeValue(forKey: taskId) {
            Task.detached { await cleanup() }
        }
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            let item = tasks.remove(at: idx)
            if deleteLocalFile, let rel = item.localRelativePath {
                let fileURL = downloadsRootURL.appendingPathComponent(rel)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        try? FileManager.default.removeItem(at: tempDir(for: taskId))
        persistTasks()
        updateIdleTimer()
        schedulePendingTasks()
    }

    public func clearCompleted(deleteFiles: Bool = false) {
        let completed = tasks.filter { $0.status == .completed }
        for item in completed {
            remove(taskId: item.id, deleteLocalFile: deleteFiles)
        }
    }

    public func localFileURL(for task: DownloadTask) -> URL? {
        guard let rel = task.localRelativePath else { return nil }
        let url = downloadsRootURL.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func totalDownloadsDiskUsage() -> Int64 {
        directorySize(downloadsRootURL) + directorySize(tempRootURL)
    }

    public func clearTempCache() {
        let activeIds = Set(tasks.filter { $0.status == .downloading || $0.status == .paused || $0.status == .pending }.map { $0.id.uuidString })
        guard let entries = try? FileManager.default.contentsOfDirectory(at: tempRootURL, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !activeIds.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - 任务调度

    private func schedulePendingTasks() {
        let maxConcurrent = settings.maxConcurrentDownloads
        var runningCount = runningJobs.count
        guard runningCount < maxConcurrent else {
            updateIdleTimer()
            return
        }

        for idx in tasks.indices.reversed() {
            if runningCount >= maxConcurrent { break }
            guard tasks[idx].status == .pending else { continue }
            let task = tasks[idx]
            tasks[idx].status = .downloading
            tasks[idx].errorMessage = nil
            runningCount += 1

            let configuredThreads = settings.threads(for: task.platform)
            let tmpDir = tempDir(for: task.id)
            let targetURL = uniqueDestinationURL(for: task.fileName)
            let relPath = targetURL.path.replacingOccurrences(of: downloadsRootURL.path + "/", with: "")

            let job = Task.detached(priority: .userInitiated) { [weak self, downloader, inflightSemaphore, speedLimiter] in
                await Self.runDownloadPipeline(
                    manager: self,
                    task: task,
                    requestedThreads: configuredThreads,
                    tmpDir: tmpDir,
                    targetURL: targetURL,
                    relativePath: relPath,
                    downloader: downloader,
                    inflightSemaphore: inflightSemaphore,
                    speedLimiter: speedLimiter
                )
            }
            runningJobs[task.id] = job
        }
        persistTasks()
        updateIdleTimer()
    }

    // MARK: - 后台并发执行管线（脱离 MainActor，避免阻塞 UI 线程）

    private nonisolated static func runDownloadPipeline(
        manager: DownloadManager?,
        task: DownloadTask,
        requestedThreads: Int,
        tmpDir: URL,
        targetURL: URL,
        relativePath: String,
        downloader: ChunkDownloader,
        inflightSemaphore: AsyncSemaphore,
        speedLimiter: SpeedLimiter
    ) async {
        let taskId = task.id
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let startedAt = Date()

        do {
            let probedTotal = await downloader.probeTotalSize(url: task.url, headers: task.headers)
            let totalSize = probedTotal ?? task.totalSize
            if totalSize > 0 {
                await MainActor.run {
                    manager?.updateTask(taskId) { $0.totalSize = totalSize }
                }
            }

            if totalSize > ChunkPlanner.minChunkBytes && probedTotal != nil {
                let effectiveWorkers = max(1, min(requestedThreads, 64))
                let plan = ChunkPlanner.makePlan(totalSize: totalSize, threads: effectiveWorkers)
                prepareTempDir(tmpDir, expectedSignature: plan.signature)

                let needFallback = try await runMultiChunkDownload(
                    manager: manager,
                    task: task,
                    plan: plan,
                    workers: effectiveWorkers,
                    tmpDir: tmpDir,
                    downloader: downloader,
                    inflightSemaphore: inflightSemaphore,
                    speedLimiter: speedLimiter
                )

                if needFallback {
                    try? FileManager.default.removeItem(at: tmpDir)
                    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                    try await runSingleStreamDownload(
                        manager: manager,
                        task: task,
                        totalSize: totalSize,
                        destinationURL: targetURL,
                        downloader: downloader,
                        speedLimiter: speedLimiter
                    )
                } else {
                    let orderedParts = collectOrderedPartFiles(in: tmpDir, plan: plan)
                    let merged = try await downloader.mergeChunks(
                        partFiles: orderedParts,
                        to: targetURL,
                        totalBytes: totalSize
                    ) { pct in
                        await MainActor.run {
                            manager?.stats[taskId] = DownloadStats(
                                speedBytesPerSec: 0,
                                remainingSeconds: nil,
                                activeWorkers: 0,
                                totalChunks: plan.totalChunks,
                                mergePercent: pct
                            )
                        }
                    }
                    try? FileManager.default.removeItem(at: tmpDir)
                    if totalSize > 0 && merged < totalSize {
                        throw HTTPClientError.httpError(0, "合并后文件大小不完整")
                    }
                }
            } else {
                try await runSingleStreamDownload(
                    manager: manager,
                    task: task,
                    totalSize: totalSize,
                    destinationURL: targetURL,
                    downloader: downloader,
                    speedLimiter: speedLimiter
                )
                try? FileManager.default.removeItem(at: tmpDir)
            }

            let elapsed = max(0.1, Date().timeIntervalSince(startedAt))
            let finalSize = ChunkDownloader.fileSize(at: targetURL)
            let avgSpeed = Int64(Double(finalSize) / elapsed)
            await MainActor.run {
                manager?.finishTaskSuccess(taskId: taskId, relativePath: relativePath, finalSize: finalSize, avgSpeed: avgSpeed)
            }
        } catch is CancellationError {
            // 用户主动暂停或删除
        } catch {
            await MainActor.run {
                manager?.finishTaskFailure(taskId: taskId, message: error.localizedDescription)
            }
        }
    }

    private nonisolated static func runMultiChunkDownload(
        manager: DownloadManager?,
        task: DownloadTask,
        plan: ChunkPlan,
        workers: Int,
        tmpDir: URL,
        downloader: ChunkDownloader,
        inflightSemaphore: AsyncSemaphore,
        speedLimiter: SpeedLimiter
    ) async throws -> Bool {
        let taskId = task.id
        let total = plan.totalSize
        let downloadedCounter = AtomicCounter(diskTempBytes(in: tmpDir))
        let rangeIgnoredCounter = AtomicCounter(0)
        let fallbackFlag = AtomicCounter(0)

        var pendingMain: [(index: Int, range: ByteRange)] = []
        for (idx, r) in plan.mainRanges.enumerated() {
            let pFile = tmpDir.appendingPathComponent("part_\(idx)")
            if ChunkDownloader.fileSize(at: pFile) < r.length {
                pendingMain.append((idx, r))
            }
        }
        let mainQueue = MainChunkQueue(items: pendingMain)

        let allocator = ElasticAllocator(
            total: total,
            elasticStart: plan.elasticStart,
            workers: workers,
            chunkSize: plan.mainChunkSize
        )
        let completedSegs = scanExistingElasticSegments(in: tmpDir)
        var elasticCursor = plan.elasticStart
        for seg in completedSegs.sorted(by: { $0.start < $1.start }) {
            if seg.start == elasticCursor && ChunkDownloader.fileSize(at: seg.url) >= seg.range.length {
                elasticCursor = seg.end + 1
            }
        }
        allocator.skipTo(elasticCursor)

        let inflightRegistry = InflightRegistry()

        // 看门狗 + 500ms UI 统计刷新任务
        let monitorTask = Task.detached {
            var prevBytes = downloadedCounter.get()
            var prevAt = Date()
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                let now = Date()
                let curBytes = min(total, downloadedCounter.get())
                let dt = max(0.1, now.timeIntervalSince(prevAt))
                let speed = Int64(Double(max(0, curBytes - prevBytes)) / dt)
                prevBytes = curBytes
                prevAt = now
                allocator.updateSpeed(speed)

                let activeTrackers = inflightRegistry.snapshot()
                let remainSec: Double? = speed > 0 ? Double(max(0, total - curBytes)) / Double(speed) : nil
                await MainActor.run {
                    manager?.updateTask(taskId, persist: false) { $0.downloadedSize = curBytes }
                    manager?.stats[taskId] = DownloadStats(
                        speedBytesPerSec: speed,
                        remainingSeconds: remainSec,
                        activeWorkers: activeTrackers.count,
                        totalChunks: plan.totalChunks
                    )
                }

                tickCount += 1
                if tickCount % 10 == 0 {
                    await MainActor.run { manager?.persistTasks() }
                    evaluateSlowPreemption(trackers: activeTrackers, totalSpeed: speed, now: now)
                }
            }
        }
        defer { monitorTask.cancel() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for workerIdx in 0..<workers {
                group.addTask {
                    let stagger = min(workerIdx, 8) * 25
                    if stagger > 0 {
                        try await Task.sleep(nanoseconds: UInt64(stagger) * 1_000_000)
                    }

                    while !Task.isCancelled && fallbackFlag.get() == 0 {
                        let workItem: (key: String, range: ByteRange, file: URL)?
                        if let next = mainQueue.popFirst() {
                            workItem = ("m\(next.index)", next.range, tmpDir.appendingPathComponent("part_\(next.index)"))
                        } else if let segRange = allocator.take() {
                            let fileName = "seg_\(segRange.start)_\(segRange.end).part"
                            workItem = ("seg@\(segRange.start)", segRange, tmpDir.appendingPathComponent(fileName))
                        } else {
                            workItem = nil
                        }

                        guard let item = workItem else { break }

                        try await inflightSemaphore.withPermit {
                            let tracker = InflightTracker(key: item.key, start: item.range.start, size: item.range.length)
                            inflightRegistry.insert(tracker, forKey: item.key)
                            defer { inflightRegistry.remove(forKey: item.key) }

                            let outcome = try await downloader.downloadChunk(
                                url: task.url,
                                range: item.range,
                                partURL: item.file,
                                headers: task.headers,
                                preemptSignal: tracker.signal
                            ) { delta in
                                tracker.addBytes(delta)
                                downloadedCounter.add(delta)
                                let limit = await MainActor.run { manager?.settings.speedLimitBytesPerSec ?? 0 }
                                if limit > 0 {
                                    await speedLimiter.consume(bytes: delta, limitBytesPerSec: limit)
                                }
                            }

                            switch outcome {
                            case .ok, .preempted:
                                break
                            case .rangeIgnored:
                                if rangeIgnoredCounter.add(1) > 3 {
                                    fallbackFlag.set(1)
                                }
                            case .failed(let reason):
                                throw HTTPClientError.httpError(0, "分片下载失败：\(reason)")
                            }
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        return fallbackFlag.get() != 0
    }

    private nonisolated static func runSingleStreamDownload(
        manager: DownloadManager?,
        task: DownloadTask,
        totalSize: Int64,
        destinationURL: URL,
        downloader: ChunkDownloader,
        speedLimiter: SpeedLimiter
    ) async throws {
        let taskId = task.id
        let counter = AtomicCounter(0)
        let monitor = Task.detached {
            var prev: Int64 = 0
            var prevAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                let now = Date()
                let cur = counter.get()
                let dt = max(0.1, now.timeIntervalSince(prevAt))
                let speed = Int64(Double(max(0, cur - prev)) / dt)
                prev = cur
                prevAt = now
                let remain: Double? = (totalSize > 0 && speed > 0) ? Double(max(0, totalSize - cur)) / Double(speed) : nil
                await MainActor.run {
                    manager?.updateTask(taskId, persist: false) { $0.downloadedSize = cur }
                    manager?.stats[taskId] = DownloadStats(
                        speedBytesPerSec: speed,
                        remainingSeconds: remain,
                        activeWorkers: 1,
                        totalChunks: 1
                    )
                }
            }
        }
        defer { monitor.cancel() }

        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        try await downloader.downloadFull(
            url: task.url,
            targetURL: destinationURL,
            headers: task.headers,
            expectedTotal: totalSize
        ) { delta in
            counter.add(delta)
            let limit = await MainActor.run { manager?.settings.speedLimitBytesPerSec ?? 0 }
            if limit > 0 {
                await speedLimiter.consume(bytes: delta, limitBytesPerSec: limit)
            }
        }
    }

    // MARK: - 慢连接抢占看门狗（对齐 Android §5.3.1）

    private nonisolated static func evaluateSlowPreemption(trackers: [InflightTracker], totalSpeed: Int64, now: Date) {
        guard !trackers.isEmpty else { return }
        let minBps: Int64 = 12 * 1024
        let isEndgame = trackers.count <= 3
        let minAge: TimeInterval = isEndgame ? 3.0 : 15.0
        let minRemain: Int64 = isEndgame ? 0 : 128 * 1024
        let avgPerWorker = totalSpeed / Int64(max(1, trackers.count))
        let threshold = max(minBps, avgPerWorker / 2)

        var preemptedThisTick = 0
        for tracker in trackers {
            if preemptedThisTick >= 2 { break }
            let snap = tracker.sample(now: now)
            guard snap.ageSec >= minAge,
                  snap.remaining >= minRemain,
                  snap.preemptCount < 3,
                  snap.cooldownOk,
                  snap.bps < threshold else {
                continue
            }
            tracker.markPreempted(now: now)
            preemptedThisTick += 1
        }
    }

    // MARK: - 状态完结与文件辅助

    private func finishTaskSuccess(taskId: UUID, relativePath: String, finalSize: Int64, avgSpeed: Int64) {
        runningJobs.removeValue(forKey: taskId)
        stats.removeValue(forKey: taskId)
        updateTask(taskId) { item in
            item.status = .completed
            item.totalSize = max(item.totalSize, finalSize)
            item.downloadedSize = max(item.totalSize, finalSize)
            item.localRelativePath = relativePath
            item.averageSpeed = avgSpeed
            item.completedAt = Date()
            item.errorMessage = nil
        }
        if let cleanup = completionCallbacks.removeValue(forKey: taskId) {
            Task.detached { await cleanup() }
        }
        onTaskCompleted?(taskId)
        updateIdleTimer()
        schedulePendingTasks()
    }

    private func finishTaskFailure(taskId: UUID, message: String) {
        runningJobs.removeValue(forKey: taskId)
        stats.removeValue(forKey: taskId)
        updateTask(taskId) { item in
            item.status = .failed
            item.errorMessage = message
        }
        updateIdleTimer()
        schedulePendingTasks()
    }

    private func updateTask(_ taskId: UUID, persist: Bool = true, mutate: (inout DownloadTask) -> Void) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        mutate(&tasks[idx])
        if persist { persistTasks() }
    }

    private func updateIdleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = hasActiveDownloads && settings.keepScreenAwakeWhileDownloading
        #endif
    }

    private func tempDir(for taskId: UUID) -> URL {
        tempRootURL.appendingPathComponent(taskId.uuidString, isDirectory: true)
    }

    private nonisolated static func prepareTempDir(_ dir: URL, expectedSignature: String) {
        let planFile = dir.appendingPathComponent("plan.txt")
        let existing = (try? String(contentsOf: planFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing != expectedSignature {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? expectedSignature.write(to: planFile, atomically: true, encoding: .utf8)
        }
    }

    private nonisolated static func scanExistingElasticSegments(in dir: URL) -> [(start: Int64, end: Int64, range: ByteRange, url: URL)] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [(Int64, Int64, ByteRange, URL)] = []
        for f in files {
            let name = f.lastPathComponent
            guard name.hasPrefix("seg_"), name.hasSuffix(".part") else { continue }
            let core = name.dropFirst(4).dropLast(5)
            let parts = core.split(separator: "_")
            if parts.count == 2, let s = Int64(parts[0]), let e = Int64(parts[1]), e >= s {
                result.append((s, e, ByteRange(start: s, end: e), f))
            }
        }
        return result
    }

    private nonisolated static func collectOrderedPartFiles(in dir: URL, plan: ChunkPlan) -> [URL] {
        var result: [URL] = []
        for i in 0..<plan.mainChunkCount {
            let url = dir.appendingPathComponent("part_\(i)")
            if FileManager.default.fileExists(atPath: url.path) {
                result.append(url)
            }
        }
        let segs = scanExistingElasticSegments(in: dir).sorted { $0.start < $1.start }
        result.append(contentsOf: segs.map(\.url))
        return result
    }

    private nonisolated static func diskTempBytes(in dir: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.reduce(0) { acc, file in
            let name = file.lastPathComponent
            guard name.hasPrefix("part_") || name.hasPrefix("seg_") else { return acc }
            return acc + ChunkDownloader.fileSize(at: file)
        }
    }

    private func uniqueDestinationURL(for relativePath: String) -> URL {
        let candidate = downloadsRootURL.appendingPathComponent(relativePath)
        let fm = FileManager.default
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        let parent = candidate.deletingLastPathComponent()
        for idx in 1...999 {
            let newName = ext.isEmpty ? "\(stem) (\(idx))" : "\(stem) (\(idx)).\(ext)"
            let next = parent.appendingPathComponent(newName)
            if !fm.fileExists(atPath: next.path) { return next }
        }
        return parent.appendingPathComponent("\(UUID().uuidString)_\(candidate.lastPathComponent)")
    }

    private func sanitizeRelativePath(_ raw: String) -> String {
        let parts = raw
            .split(separator: "/")
            .map { seg in
                String(seg)
                    .replacingOccurrences(of: ":", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: "..", with: "_")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "download_\(Int(Date().timeIntervalSince1970))" : parts.joined(separator: "/")
    }

    private func inferFileName(from urlString: String) -> String {
        if let url = URL(string: urlString), !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
            return url.lastPathComponent
        }
        return "file_\(Int(Date().timeIntervalSince1970))"
    }

    private func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func loadTasks() {
        guard let data = try? Data(contentsOf: tasksFileURL),
              let decoded = try? JSONDecoder().decode([DownloadTask].self, from: data) else {
            return
        }
        self.tasks = decoded
    }

    private func markInterruptedAsPaused() {
        var changed = false
        for idx in tasks.indices where tasks[idx].status == .downloading || tasks[idx].status == .pending {
            tasks[idx].status = .paused
            changed = true
        }
        if changed { persistTasks() }
    }

    private func persistTasks() {
        if let data = try? JSONEncoder().encode(tasks) {
            try? data.write(to: tasksFileURL, options: .atomic)
        }
    }
}
