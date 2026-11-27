//
//  CloudDriveModels.swift
//  YunX
//
//  个人网盘领域模型：容量配额、支持个人盘的平台集合与根目录约定。
//

import Foundation

public struct CloudQuota: Equatable, Sendable {
    public let used: Int64
    public let total: Int64
    public let usedInTrash: Int64

    public init(used: Int64, total: Int64, usedInTrash: Int64 = 0) {
        self.used = max(0, used)
        self.total = max(0, total)
        self.usedInTrash = max(0, usedInTrash)
    }

    public var usageRatio: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(used) / Double(total)))
    }
}

public extension SharePlatform {
    /// 支持个人网盘文件管理与分享转存的 8 大网盘平台
    static let cloudDrivePlatforms: [SharePlatform] = [
        .quark, .uc, .pan123, .pan115, .c139, .xunlei, .guangya, .baidu
    ]

    var supportsCloudDrive: Bool {
        Self.cloudDrivePlatforms.contains(self)
    }

    /// 个人网盘根目录 ID（注意 139 分享根为 "root"，但个人盘管理接口根为 "/"）
    var cloudRootDirFid: String {
        switch self {
        case .quark, .uc, .pan123, .pan115:
            return "0"
        case .c139, .baidu:
            return "/"
        case .xunlei, .guangya:
            return ""
        default:
            return ""
        }
    }
}
