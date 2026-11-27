//
//  VideoModels.swift
//  YunX
//
//  视频/图文平台枚举、媒体条目、解析结果与错误分类模型（对齐 Android Core/Video 体系）。
//

import Foundation

public enum VideoPlatform: String, CaseIterable, Codable, Sendable, Identifiable {
    case douyin
    case kuaishou
    case weibo
    case acfun
    case bilibili
    case xhs
    case pixiv

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .bilibili: return "哔哩哔哩"
        case .xhs: return "小红书"
        case .pixiv: return "Pixiv"
        }
    }

    public var brandHex: UInt32 {
        switch self {
        case .douyin: return 0x161823
        case .kuaishou: return 0xFF4906
        case .weibo: return 0xE6162D
        case .acfun: return 0xFD4C5D
        case .bilibili: return 0xFB7299
        case .xhs: return 0xFF2442
        case .pixiv: return 0x0096FA
        }
    }

    public var symbolName: String {
        switch self {
        case .douyin: return "music.note"
        case .kuaishou: return "video.fill"
        case .weibo: return "flame.fill"
        case .acfun: return "play.tv.fill"
        case .bilibili: return "tv.fill"
        case .xhs: return "book.pages.fill"
        case .pixiv: return "paintbrush.pointed.fill"
        }
    }

    public var loginURL: String {
        switch self {
        case .bilibili: return "https://passport.bilibili.com/login"
        case .xhs: return "https://www.xiaohongshu.com/login"
        default: return ""
        }
    }

    public var cookieDomain: String {
        switch self {
        case .bilibili: return "bilibili.com"
        case .xhs: return "xiaohongshu.com"
        case .pixiv: return "pixiv.net"
        default: return ""
        }
    }

    public var manualCookieOnly: Bool {
        self == .pixiv
    }

    public var needsLogin: Bool {
        !loginURL.isEmpty || manualCookieOnly
    }

    public var loginBenefit: String {
        switch self {
        case .bilibili: return "登录后可解锁 1080P / 4K 高清视频流"
        case .xhs: return "小红书网页端需要登录后方可解析图文与视频笔记"
        case .pixiv: return "仅支持手动粘贴 Cookie（PHPSESSID），解锁全量与受限插画原图"
        default: return "支持免登录匿名解析"
        }
    }

    /// 备份键名（与 Android AuthBackupManager `video:BILIBILI` 1:1 兼容）
    public var backupKey: String {
        "video:\(rawValue.uppercased())"
    }

    public static func fromBackupPlatform(_ raw: String) -> VideoPlatform? {
        guard raw.hasPrefix("video:") else { return nil }
        let suffix = String(raw.dropFirst("video:".count)).lowercased()
        return VideoPlatform(rawValue: suffix)
    }

    /// 需要展示账号入口的视频平台
    public static let loginPlatforms: [VideoPlatform] = [.bilibili, .xhs, .pixiv]
}

public enum VideoMediaKind: String, Sendable, Equatable {
    case video
    case image
    case audio

    public var label: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        case .audio: return "音频"
        }
    }
}

public struct VideoMedia: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: String
    public let kind: VideoMediaKind
    public let fileName: String
    public let size: Int64
    public let isHls: Bool
    public let headers: [String: String]
    public let quality: String
    public let audioUrl: String
    public let audioHeaders: [String: String]
    public let motionUrl: String

    public init(
        url: String,
        kind: VideoMediaKind,
        fileName: String = "",
        size: Int64 = -1,
        isHls: Bool = false,
        headers: [String: String] = [:],
        quality: String = "",
        audioUrl: String = "",
        audioHeaders: [String: String] = [:],
        motionUrl: String = ""
    ) {
        self.id = "\(kind.rawValue)|\(quality)|\(fileName)|\(url)"
        self.url = url
        self.kind = kind
        self.fileName = fileName
        self.size = size
        self.isHls = isHls
        self.headers = headers
        self.quality = quality
        self.audioUrl = audioUrl
        self.audioHeaders = audioHeaders
        self.motionUrl = motionUrl
    }

    public func withSecureURLs() -> VideoMedia {
        VideoMedia(
            url: VideoHTTP.secureURL(url),
            kind: kind,
            fileName: fileName,
            size: size,
            isHls: isHls,
            headers: headers,
            quality: quality,
            audioUrl: VideoHTTP.secureURL(audioUrl),
            audioHeaders: audioHeaders,
            motionUrl: VideoHTTP.secureURL(motionUrl)
        )
    }
}

public struct VideoParseResult: Equatable, Sendable {
    public let platform: VideoPlatform
    public let title: String
    public let author: String
    public let avatar: String
    public let cover: String
    public let text: String
    public let timestampSeconds: Int64
    public let url: String
    public let medias: [VideoMedia]
    public let notice: String

    public init(
        platform: VideoPlatform,
        title: String,
        author: String = "",
        avatar: String = "",
        cover: String = "",
        text: String = "",
        timestampSeconds: Int64 = 0,
        url: String = "",
        medias: [VideoMedia] = [],
        notice: String = ""
    ) {
        self.platform = platform
        self.title = title
        self.author = author
        self.avatar = avatar
        self.cover = cover
        self.text = text
        self.timestampSeconds = timestampSeconds
        self.url = url
        self.medias = medias
        self.notice = notice
    }

    public var videoCount: Int { medias.filter { $0.kind == .video }.count }
    public var imageCount: Int { medias.filter { $0.kind == .image }.count }

    public func withSecureURLs() -> VideoParseResult {
        VideoParseResult(
            platform: platform,
            title: title,
            author: author,
            avatar: VideoHTTP.secureURL(avatar),
            cover: VideoHTTP.secureURL(cover),
            text: text,
            timestampSeconds: timestampSeconds,
            url: url,
            medias: medias.map { $0.withSecureURLs() },
            notice: notice
        )
    }
}

public struct DetectedVideoLink: Equatable, Sendable {
    public let platform: VideoPlatform
    public let kind: String
    public let id: String
    public let url: String
    public let isShortLink: Bool

    public init(platform: VideoPlatform, kind: String, id: String, url: String, isShortLink: Bool = false) {
        self.platform = platform
        self.kind = kind
        self.id = id
        self.url = url
        self.isShortLink = isShortLink
    }
}

public enum VideoParseErrorKind: Sendable, Equatable {
    case blocked
    case notFound
    case network
    case unsupported
    case unknown
}

public struct VideoParseError: LocalizedError, Sendable {
    public let kind: VideoParseErrorKind
    public let message: String

    public init(_ kind: VideoParseErrorKind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? {
        switch kind {
        case .blocked:
            return message.isEmpty ? "触发平台风控或验证码拦截，请稍后重试或登录账号" : message
        case .notFound:
            return message.isEmpty ? "作品不存在、已删除或设为私密" : message
        case .network:
            return message.isEmpty ? "网络请求失败，请检查网络连接" : message
        case .unsupported:
            return message.isEmpty ? "暂不支持该链接形态或需要先登录账号" : message
        case .unknown:
            return message.isEmpty ? "解析失败，平台页面结构可能已变更" : message
        }
    }
}
