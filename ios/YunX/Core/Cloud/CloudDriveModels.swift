//
//  CloudDriveModels.swift
//  YunX
//
//  个人网盘领域模型：容量配额、分享有效期中性码与各平台转换、分享结果、支持个人盘的平台集合与根目录约定。
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

/// 个人盘创建分享的有效期中性枚举（与各平台实际协议字段严格隔离转换，避免码位错乱）
public enum CloudShareExpire: Int, CaseIterable, Identifiable, Sendable, Equatable {
    case unknown = 0
    case forever = 1
    case oneDay = 2
    case sevenDays = 3
    case thirtyDays = 4
    case threeDays = 103
    case fifteenDays = 105

    public var id: Int { rawValue }

    public var displayTitle: String {
        switch self {
        case .forever: return "永久有效"
        case .oneDay: return "1 天"
        case .threeDays: return "3 天"
        case .sevenDays: return "7 天"
        case .fifteenDays: return "15 天"
        case .thirtyDays: return "30 天"
        case .unknown: return "未知"
        }
    }

    /// 各平台可选的有效期档位（115 为专属 5 档，其余 7 大网盘为通用 4 档）
    public static func options(for platform: SharePlatform) -> [CloudShareExpire] {
        if platform == .pan115 {
            return [.forever, .oneDay, .threeDays, .sevenDays, .fifteenDays]
        }
        return [.forever, .oneDay, .sevenDays, .thirtyDays]
    }

    /// 天数（永久返回 nil，供 139 / 光鸭 / 123 换算）
    public var daysOrNull: Int? {
        switch self {
        case .forever: return nil
        case .oneDay: return 1
        case .threeDays: return 3
        case .sevenDays: return 7
        case .fifteenDays: return 15
        case .thirtyDays: return 30
        case .unknown: return nil
        }
    }

    /// 夸克 / UC 的 expired_type（1 永久 / 2 一天 / 3 七天 / 4 三十天）
    public var quarkUCExpiredType: Int {
        switch self {
        case .forever: return 1
        case .oneDay: return 2
        case .sevenDays: return 3
        case .thirtyDays: return 4
        case .threeDays: return 3
        case .fifteenDays: return 4
        case .unknown: return 3
        }
    }

    /// 百度网盘 period（0 永久 / 1 / 7 / 30）
    public var baiduPeriod: Int {
        daysOrNull ?? 0
    }

    /// 迅雷 expiration_days 字符串（"-1" 永久 / "1" / "7" / "30"）
    public var xunleiDays: String {
        if let days = daysOrNull { return String(days) }
        return "-1"
    }

    /// 115 网盘 share_duration 字符串（"-1" 长期 / "1" / "3" / "7" / "15"）
    public var pan115Duration: String {
        switch self {
        case .forever: return "-1"
        case .oneDay: return "1"
        case .threeDays: return "3"
        case .sevenDays: return "7"
        case .fifteenDays, .thirtyDays: return "15"
        case .unknown: return "7"
        }
    }

    /// 123 云盘绝对 ISO 时间字符串（+08:00；永久使用 2099 哨兵）
    public func pan123ExpirationString(now: Date = Date()) -> String {
        guard let days = daysOrNull else {
            return "2099-12-12T08:00:00+08:00"
        }
        let target = now.addingTimeInterval(TimeInterval(days) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+08:00'"
        return formatter.string(from: target)
    }

    public static func fromQuarkUC(_ value: Int) -> CloudShareExpire {
        switch value {
        case 1: return .forever
        case 2: return .oneDay
        case 3: return .sevenDays
        case 4: return .thirtyDays
        default: return .unknown
        }
    }

    public static func fromBaiduPeriod(_ value: Int?) -> CloudShareExpire? {
        guard let value else { return nil }
        switch value {
        case 0: return .forever
        case 1: return .oneDay
        case 7: return .sevenDays
        case 30: return .thirtyDays
        default: return nil
        }
    }

    public static func fromPan115Duration(_ raw: String) -> CloudShareExpire {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "-1", "长期", "永久": return .forever
        case "1", "1天": return .oneDay
        case "3", "3天": return .threeDays
        case "7", "7天": return .sevenDays
        case "15", "15天": return .fifteenDays
        default: return .unknown
        }
    }
}

/// 创建个人网盘分享链接的统一结果模型
public struct CloudShareResult: Equatable, Sendable, Identifiable {
    public let id: String
    public let platform: SharePlatform
    public let shareUrl: String
    public let passcode: String
    public let pwdId: String
    public let title: String
    public let expire: CloudShareExpire
    public let warning: String?

    public init(
        platform: SharePlatform,
        shareUrl: String,
        passcode: String = "",
        pwdId: String = "",
        title: String = "",
        expire: CloudShareExpire = .unknown,
        warning: String? = nil
    ) {
        self.id = "\(platform.rawValue)|\(pwdId)|\(shareUrl)"
        self.platform = platform
        self.shareUrl = shareUrl
        self.passcode = passcode
        self.pwdId = pwdId
        self.title = title
        self.expire = expire
        self.warning = warning
    }

    public var formattedCopyText: String {
        var lines: [String] = []
        if !title.isEmpty {
            lines.append("「\(title)」")
        }
        lines.append("链接：\(shareUrl)")
        if !passcode.isEmpty {
            lines.append("提取码：\(passcode)")
        }
        return lines.joined(separator: "\n")
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

    /// 创建分享时是否支持用户自定义提取码（115 / 139 由服务端自动分配）
    var supportsCustomSharePasscode: Bool {
        switch self {
        case .pan115, .c139:
            return false
        default:
            return supportsCloudDrive
        }
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

    /// 生成 4 位字母数字随机提取码（百度必填，其它平台可选）
    static func randomSharePasscode(length: Int = 4) -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<max(length, 4)).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}
