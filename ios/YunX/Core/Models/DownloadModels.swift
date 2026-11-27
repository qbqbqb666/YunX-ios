//
//  DownloadModels.swift
//  YunX
//
//  下载任务、状态枚举、实时统计与分片规划模型。
//

import Foundation

public enum DownloadStatus: String, Codable, Sendable {
    case pending
    case downloading
    case paused
    case completed
    case failed

    public var label: String {
        switch self {
        case .pending: return "等待中"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
}

/// 持久化下载任务模型
public struct DownloadTask: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var fileName: String
    public var url: String
    public var headers: [String: String]
    public var platform: DownloadPlatform
    public var totalSize: Int64
    public var downloadedSize: Int64
    public var status: DownloadStatus
    public var localRelativePath: String?
    public var errorMessage: String?
    public var averageSpeed: Int64
    public var createdAt: Date
    public var completedAt: Date?
    /// 若为文件夹/批量下载，取第一个 `/` 前作为分组名
    public var folderGroup: String? {
        guard let slashIndex = fileName.firstIndex(of: "/") else { return nil }
        let prefix = String(fileName[..<slashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix
    }

    public var displayFileName: String {
        if let slashIndex = fileName.lastIndex(of: "/") {
            let tail = String(fileName[fileName.index(after: slashIndex)...])
            return tail.isEmpty ? fileName : tail
        }
        return fileName
    }

    public var progress: Double {
        guard totalSize > 0 else { return status == .completed ? 1.0 : 0.0 }
        return min(1.0, max(0.0, Double(downloadedSize) / Double(totalSize)))
    }

    public init(
        id: UUID = UUID(),
        fileName: String,
        url: String,
        headers: [String: String] = [:],
        platform: DownloadPlatform = .generic,
        totalSize: Int64 = 0,
        downloadedSize: Int64 = 0,
        status: DownloadStatus = .pending,
        localRelativePath: String? = nil,
        errorMessage: String? = nil,
        averageSpeed: Int64 = 0,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.url = url
        self.headers = headers
        self.platform = platform
        self.totalSize = totalSize
        self.downloadedSize = downloadedSize
        self.status = status
        self.localRelativePath = localRelativePath
        self.errorMessage = errorMessage
        self.averageSpeed = averageSpeed
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// 内存态高频下载统计（避免每次收包写盘引起 UI 卡顿）
public struct DownloadStats: Equatable, Sendable {
    public var speedBytesPerSec: Int64
    public var remainingSeconds: Double?
    public var activeWorkers: Int
    public var totalChunks: Int
    /// 合并阶段进度（0~100）；nil 表示非合并阶段
    public var mergePercent: Int?

    public init(
        speedBytesPerSec: Int64 = 0,
        remainingSeconds: Double? = nil,
        activeWorkers: Int = 0,
        totalChunks: Int = 1,
        mergePercent: Int? = nil
    ) {
        self.speedBytesPerSec = speedBytesPerSec
        self.remainingSeconds = remainingSeconds
        self.activeWorkers = activeWorkers
        self.totalChunks = totalChunks
        self.mergePercent = mergePercent
    }
}
