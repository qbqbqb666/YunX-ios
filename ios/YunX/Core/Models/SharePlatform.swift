//
//  SharePlatform.swift
//  YunX
//
//  网盘平台枚举与基础元信息（与原 Android 端 ShareLinkParser / DownloadPlatform 保持口径一致）。
//

import Foundation

public enum SharePlatform: String, CaseIterable, Codable, Sendable, Identifiable {
    case quark
    case uc
    case pan123
    case lanzou
    case xunlei
    case baidu
    case c139
    case pan115
    case guangya
    case ilanzou
    case github

    public var id: String { rawValue }

    /// 界面展示名（单一真源）
    public var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .pan123: return "123 云盘"
        case .lanzou: return "蓝奏云"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏优享"
        case .github: return "GitHub"
        }
    }

    /// 简短徽章文字
    public var shortLabel: String {
        switch self {
        case .quark: return "夸克"
        case .uc: return "UC"
        case .pan123: return "123"
        case .lanzou: return "蓝奏"
        case .xunlei: return "迅雷"
        case .baidu: return "百度"
        case .c139: return "139"
        case .pan115: return "115"
        case .guangya: return "光鸭"
        case .ilanzou: return "优享"
        case .github: return "GH"
        }
    }

    /// 当前已实现完整解析下载的平台（Phase 1 + Phase 2 全部 10 大平台）
    public var isSupported: Bool {
        switch self {
        case .quark, .uc, .pan123, .lanzou, .pan115, .c139, .xunlei, .guangya, .baidu, .github:
            return true
        case .ilanzou:
            return false
        }
    }

    /// 兼容旧属性名
    public var isPhase1Supported: Bool { isSupported }

    /// 未登录（游客）是否可直接获取分享下载直链
    public var supportsGuestDownload: Bool {
        switch self {
        case .quark, .uc, .lanzou, .guangya, .github:
            return true
        default:
            return false
        }
    }

    /// 游客模式提示文案
    public var guestNotice: String {
        switch self {
        case .quark:
            return "未登录游客模式：可浏览文件，约 50MB 以内小文件可直接下载；大文件请先在「账号」页登录夸克。"
        case .uc:
            return "未登录游客模式：可浏览并直接高速下载；登录后支持视频原画直链与转存。"
        case .lanzou:
            return "蓝奏云分享链接支持免登录直接解析与高速下载。"
        case .pan123:
            return "未登录游客模式：可查看文件列表，获取下载直链需先在「账号」页登录 123 云盘。"
        case .pan115:
            return "未登录游客模式：可浏览分享目录，下载文件（含大文件电脑端通道）需先在「账号」页登录 115 网盘。"
        case .c139:
            return "未登录游客模式：可匿名浏览目录，获取 OBS 高速直链需先在「账号」页登录 139 云盘。"
        case .xunlei:
            return "未登录游客模式：可匿名浏览目录，下载需先登录迅雷网盘（下载并发自动固定为 8 线程以防限流）。"
        case .guangya:
            return "光鸭云盘公开分享支持免登录直接高速下载；若分享者限制免登录（207），登录后将自动临时转存下载。"
        case .baidu:
            return "未登录游客模式：可浏览公开分享；登录百度网盘高速下载存在限速/风控可能，请酌情使用。"
        case .github:
            return "GitHub 支持免登录浏览仓库/Release 与高速下载；若触发 API 限流，可在「账号」页配置 Personal Access Token。"
        case .ilanzou:
            return "蓝奏优享将在后续版本接入。"
        }
    }

    /// 下载根目录默认目录 ID
    public var rootDirFid: String {
        switch self {
        case .quark, .uc, .pan123, .pan115:
            return "0"
        case .c139:
            return "root"
        case .baidu:
            return "/"
        case .lanzou, .xunlei, .guangya, .ilanzou, .github:
            return ""
        }
    }

    /// 备份文件中使用的平台标识键（与 Android AuthBackupManager 保持 1:1 兼容）
    public var backupKey: String { rawValue }

    /// 品牌强调色十六进制值
    public var brandHex: UInt32 {
        switch self {
        case .quark: return 0x4C8BF5
        case .uc: return 0xFF7A1A
        case .pan123: return 0x2B7FFF
        case .lanzou: return 0x22A06B
        case .xunlei: return 0x1677FF
        case .baidu: return 0x2932E1
        case .c139: return 0x0085D0
        case .pan115: return 0x2777F8
        case .guangya: return 0xF59E0B
        case .ilanzou: return 0x10B981
        case .github: return 0x24292F
        }
    }

    /// 平台 SF Symbol 图标名
    public var symbolName: String {
        switch self {
        case .quark: return "sparkles"
        case .uc: return "bolt.circle.fill"
        case .pan123: return "cloud.fill"
        case .lanzou: return "paperplane.fill"
        case .xunlei: return "hare.fill"
        case .baidu: return "externaldrive.fill"
        case .c139: return "antenna.radiowaves.left.and.right"
        case .pan115: return "tray.full.fill"
        case .guangya: return "sun.max.fill"
        case .ilanzou: return "wind"
        case .github: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// 下载任务来源平台标识（用于控制按平台线程数策略，例如迅雷固定 8 线程）
public enum DownloadPlatform: String, Codable, Sendable {
    case quark
    case uc
    case pan123
    case lanzou
    case xunlei
    case baidu
    case c139
    case pan115
    case guangya
    case ilanzou
    case github
    case video
    case generic

    public init(sharePlatform: SharePlatform) {
        self = DownloadPlatform(rawValue: sharePlatform.rawValue) ?? .generic
    }

    public var displayName: String {
        if let sp = SharePlatform(rawValue: rawValue) {
            return sp.shortLabel
        }
        switch self {
        case .video: return "视频"
        default: return "直链"
        }
    }
}
