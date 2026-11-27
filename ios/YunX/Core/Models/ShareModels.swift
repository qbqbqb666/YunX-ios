//
//  ShareModels.swift
//  YunX
//
//  分享会话、文件条目、缩略图、下载直链与账号记录领域模型。
//

import Foundation

/// 链接解析结果：shareId + 提取码 + 归属平台
public struct ParsedShare: Equatable, Sendable {
    public let shareId: String
    public let pwd: String?
    public let platform: SharePlatform
    public let rawUrl: String

    public init(shareId: String, pwd: String?, platform: SharePlatform, rawUrl: String) {
        self.shareId = shareId
        self.pwd = pwd
        self.platform = platform
        self.rawUrl = rawUrl
    }
}

/// 分享解析会话（一次解析流程的上下文凭证）
public struct ShareSession: Equatable, Sendable {
    public let platform: SharePlatform
    public let shareId: String
    public let stoken: String
    public let title: String
    public let originalLink: String
    public let passcode: String?

    public init(
        platform: SharePlatform,
        shareId: String,
        stoken: String,
        title: String,
        originalLink: String,
        passcode: String? = nil
    ) {
        self.platform = platform
        self.shareId = shareId
        self.stoken = stoken
        self.title = title
        self.originalLink = originalLink
        self.passcode = passcode
    }
}

/// 列表行缩略图：带按 host 隔离的请求头
public struct FileThumbnail: Equatable, Sendable {
    public let url: String
    public let headers: [String: String]

    public init(url: String, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    public static func secure(url: String, headers: [String: String] = [:]) -> FileThumbnail? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("https://") else { return nil }
        return FileThumbnail(url: trimmed, headers: headers)
    }

    /// 仅当缩略图域名与官方 authHost 一致时才附带登录态请求头，防止凭证泄漏到外部 CDN
    public static func hostScoped(
        url: String,
        headers: [String: String],
        authHost: String,
        authHeaders: [String: String]
    ) -> FileThumbnail? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("https://"),
              let host = URL(string: trimmed)?.host else {
            return nil
        }
        let chosen = host.caseInsensitiveCompare(authHost) == .orderedSame ? authHeaders : headers
        return FileThumbnail(url: trimmed, headers: chosen)
    }
}

/// 文件/文件夹条目
public struct ShareFile: Identifiable, Equatable, Hashable, Sendable {
    public let fid: String
    public let fname: String
    public let fsize: Int64
    public let isdir: Bool
    public let pdirFid: String
    public let fidToken: String
    public let modifyTime: String
    public let thumbnail: FileThumbnail?

    public var id: String { "\(pdirFid):\(fid):\(fname)" }

    public init(
        fid: String,
        fname: String,
        fsize: Int64,
        isdir: Bool,
        pdirFid: String = "",
        fidToken: String = "",
        modifyTime: String = "",
        thumbnail: FileThumbnail? = nil
    ) {
        self.fid = fid
        self.fname = fname
        self.fsize = fsize
        self.isdir = isdir
        self.pdirFid = pdirFid
        self.fidToken = fidToken
        self.modifyTime = modifyTime
        self.thumbnail = thumbnail
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fid)
        hasher.combine(pdirFid)
        hasher.combine(fname)
    }
}

/// 解析得到的下载直链
public struct DownloadLink: Equatable, Sendable {
    public let fid: String
    public let filename: String
    public let downloadUrl: String
    public let size: Int64
    /// 夸克等平台临时转存子目录 fid，下载完成后自动清理
    public let cleanupDirFid: String?
    /// 是否为 HLS 转码流（.m3u8）
    public let isHls: Bool
    /// 游客直链绑定的当次响应 Cookie（例如夸克/UC 的 `__pugs=...`）
    public let guestCookie: String

    public init(
        fid: String,
        filename: String,
        downloadUrl: String,
        size: Int64,
        cleanupDirFid: String? = nil,
        isHls: Bool = false,
        guestCookie: String = ""
    ) {
        self.fid = fid
        self.filename = filename
        self.downloadUrl = downloadUrl
        self.size = size
        self.cleanupDirFid = cleanupDirFid
        self.isHls = isHls
        self.guestCookie = guestCookie
    }

    public func withFilename(_ newName: String) -> DownloadLink {
        DownloadLink(
            fid: fid,
            filename: newName,
            downloadUrl: downloadUrl,
            size: size,
            cleanupDirFid: cleanupDirFid,
            isHls: isHls,
            guestCookie: guestCookie
        )
    }

    public func withCleanupDirFid(_ dirFid: String?) -> DownloadLink {
        DownloadLink(
            fid: fid,
            filename: filename,
            downloadUrl: downloadUrl,
            size: size,
            cleanupDirFid: dirFid,
            isHls: isHls,
            guestCookie: guestCookie
        )
    }
}

/// 平台账号记录（敏感凭证本体存 Keychain，此处仅存非敏感元数据 + 关联键）
public struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
    public let platform: SharePlatform
    public var nickname: String
    public var accountIdentifier: String
    public var updatedAt: Int64

    public var id: String { platform.rawValue }

    public init(
        platform: SharePlatform,
        nickname: String = "",
        accountIdentifier: String = "",
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.platform = platform
        self.nickname = nickname
        self.accountIdentifier = accountIdentifier
        self.updatedAt = updatedAt
    }
}
