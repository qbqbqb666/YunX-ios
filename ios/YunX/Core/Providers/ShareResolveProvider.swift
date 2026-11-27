//
//  ShareResolveProvider.swift
//  YunX
//
//  网盘分享解析公共协议接口、错误类型与统一请求头构造器。
//

import Foundation

public enum ProviderError: LocalizedError, Sendable {
    case unrecognizedLink
    case platformNotYetSupported(SharePlatform)
    case loginRequired(SharePlatform)
    case apiMessage(String, code: Int? = nil)
    case missingData(String)

    public var errorDescription: String? {
        switch self {
        case .unrecognizedLink:
            return "无法识别该分享链接，请确认链接是否完整"
        case .platformNotYetSupported(let platform):
            return "\(platform.displayName) 将在后续版本接入"
        case .loginRequired(let platform):
            return "请先到「账号」页登录\(platform.displayName)"
        case .apiMessage(let msg, let code):
            if let code, code != 0 {
                return "\(msg)（错误码 \(code)）"
            }
            return msg
        case .missingData(let msg):
            return msg
        }
    }
}

/// 所有网盘解析器的统一协议（与 Android ShareResolveRepository 1:1 对应）
public protocol ShareResolveProvider: Sendable {
    var platform: SharePlatform { get }

    /// 创建分享会话（获取 stoken / 校验提取码）
    func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession

    /// 列出分享目录文件（全部网盘均支持匿名列目录）
    func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile]

    /// 登录态获取下载直链（preferNoSave 决定夸克是否优先免转存）
    func getShareDownloadLink(session: ShareSession, file: ShareFile, credential: String, preferNoSave: Bool) async throws -> DownloadLink

    /// 游客态（未登录）获取下载直链（仅夸克/UC/蓝奏支持）
    func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink

    /// 下载完成后清理临时转存子目录（夸克实现，其余默认空操作）
    func cleanupTempDir(dirFid: String, credential: String) async

    /// 校验登录凭证并拉取账号昵称（返回 nil 表示凭证失效）
    func fetchNickname(credential: String) async -> String?
}

public extension ShareResolveProvider {
    func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        throw ProviderError.loginRequired(platform)
    }

    func cleanupTempDir(dirFid: String, credential: String) async {}

    func fetchNickname(credential: String) async -> String? { nil }
}

/// 按平台组装下载/在线预览请求头（与 Android ResolveViewModel.buildDownloadHeaders 逐字段一致）
public enum DownloadHeaderBuilder {
    public static func buildHeaders(
        platform: SharePlatform,
        credential: String,
        link: DownloadLink
    ) -> [String: String] {
        let isGuest = !link.guestCookie.isEmpty
        switch platform {
        case .quark:
            return [
                "Cookie": isGuest ? link.guestCookie : credential,
                "User-Agent": QuarkConstants.apiUserAgent,
                "Referer": QuarkConstants.downloadReferer
            ]
        case .uc:
            if isGuest {
                return [
                    "Cookie": link.guestCookie,
                    "User-Agent": UCConstants.guestUA,
                    "Sec-Ch-Ua": UCConstants.guestSecChUA,
                    "Referer": UCConstants.downloadReferer,
                    "Origin": UCConstants.webOrigin
                ]
            } else {
                return [
                    "Cookie": credential,
                    "User-Agent": UCConstants.userAgent,
                    "Referer": UCConstants.downloadReferer,
                    "Origin": UCConstants.webOrigin
                ]
            }
        case .pan123:
            return [
                "User-Agent": Pan123Constants.webUA,
                "Referer": Pan123Constants.downloadReferer
            ]
        case .lanzou:
            let origin: String
            if let url = URL(string: link.downloadUrl), let scheme = url.scheme, let host = url.host {
                origin = "\(scheme)://\(host)"
            } else {
                origin = "https://pan.lanzoui.com"
            }
            return [
                "User-Agent": LanzouConstants.webUA,
                "Referer": "\(origin)/",
                "Cookie": LanzouConstants.downIPCookie
            ]
        case .pan115:
            return [
                "Cookie": Pan115Constants.mergeCookies(credential, link.guestCookie),
                "User-Agent": Pan115Constants.clientUA,
                "Referer": Pan115Constants.downloadReferer
            ]
        case .c139:
            return [
                "User-Agent": C139Constants.pcUA
            ]
        case .xunlei:
            // 迅雷 CDN 必须使用客户端 UA，浏览器 UA 会触发 200 单流降级
            return [
                "User-Agent": XunleiConstants.appUA
            ]
        case .guangya:
            return [
                "User-Agent": GuangYaConstants.webUA,
                "Referer": GuangYaConstants.downloadReferer
            ]
        case .ilanzou:
            return [
                "User-Agent": ILanzouConstants.webUA,
                "Referer": ILanzouConstants.downloadReferer,
                "Origin": ILanzouConstants.downloadOrigin
            ]
        case .baidu:
            var h: [String: String] = [
                "User-Agent": BaiduConstants.uaNetdisk
            ]
            if !credential.isEmpty {
                h["Cookie"] = credential
            }
            return h
        case .github:
            var h: [String: String] = [
                "User-Agent": GitHubProvider.userAgent
            ]
            let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                h["Authorization"] = "Bearer \(token)"
            }
            return h
        }
    }
}
