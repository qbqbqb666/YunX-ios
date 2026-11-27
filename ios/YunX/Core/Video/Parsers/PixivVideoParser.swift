//
//  PixivVideoParser.swift
//  YunX
//
//  Pixiv 插画/漫画原图解析器：ajax/illust + /pages 提取每页原图直链并附带 i.pximg.net 防盗链 Referer。
//

import Foundation

public struct PixivVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .pixiv

    private static let referer = "https://www.pixiv.net/"

    public init() {}

    public func validateCookie(_ cookie: String) async -> String? {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let resp = try? await VideoHTTP.request(
            url: "https://www.pixiv.net/dashboard/works",
            headers: apiHeaders(cookie: trimmed),
            followRedirects: false
        ) else {
            return ""
        }
        guard (300..<400).contains(resp.statusCode) else { return "" }
        let loc = (resp.header("Location") ?? "").lowercased()
        let blocked = loc.contains("return_to=") || loc.contains("/login") || loc.contains("accounts.pixiv.net")
        return blocked ? nil : ""
    }

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let headers = apiHeaders(cookie: cookie)
        let info = try await VideoHTTP.getJSON(
            url: "https://www.pixiv.net/ajax/illust/\(link.id)",
            headers: headers,
            what: "Pixiv 作品信息"
        )
        if (info["error"] as? Bool) == true {
            let msg = VideoHTTP.str(info["message"])
            let lower = msg.lowercased()
            if lower.contains("not found") {
                throw VideoParseError(.notFound, "Pixiv 作品不存在或已被作者删除")
            }
            if lower.contains("login") || lower.contains("session") || cookie.isEmpty {
                throw VideoParseError(.unsupported, "该 Pixiv 作品需要登录态（PHPSESSID），请在「账号」页手动粘贴 Cookie")
            }
            throw VideoParseError(.blocked, "Pixiv 返回错误：\(msg)")
        }

        guard let body = info["body"] as? [String: Any] else {
            throw VideoParseError(.unknown, "Pixiv 响应缺少作品内容")
        }
        if VideoHTTP.int64(body["illustType"]) == 2 {
            throw VideoParseError(.unsupported, "暂不支持 Pixiv 动图（ugoira）打包解析")
        }

        let pagesJSON = try? await VideoHTTP.getJSON(
            url: "https://www.pixiv.net/ajax/illust/\(link.id)/pages",
            headers: headers,
            what: "Pixiv 分页原图"
        )
        let pages = pagesJSON?["body"] as? [[String: Any]] ?? []
        let title = VideoHTTP.str(body["title"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "pixiv_\(link.id)")
        let mHeaders = mediaHeaders(cookie: cookie)

        var medias: [VideoMedia] = []
        for (idx, page) in pages.enumerated() {
            let original = VideoHTTP.str((page["urls"] as? [String: Any])?["original"])
            guard !original.isEmpty else { continue }
            medias.append(VideoMedia(
                url: original,
                kind: .image,
                fileName: "\(base)_\(idx + 1).\(Self.extensionOf(original))",
                headers: mHeaders,
                quality: "原图"
            ))
        }
        if medias.isEmpty {
            let original = VideoHTTP.str((body["urls"] as? [String: Any])?["original"])
            if !original.isEmpty {
                medias.append(VideoMedia(
                    url: original,
                    kind: .image,
                    fileName: "\(base).\(Self.extensionOf(original))",
                    headers: mHeaders,
                    quality: "原图"
                ))
            }
        }
        guard !medias.isEmpty else {
            throw VideoParseError(.notFound, "Pixiv 作品未返回可下载原图")
        }

        return VideoParseResult(
            platform: .pixiv,
            title: title,
            author: VideoHTTP.str(body["userName"]),
            cover: medias[0].url,
            text: VideoHTTP.str(body["description"]).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression),
            url: "https://www.pixiv.net/artworks/\(link.id)",
            medias: medias
        )
    }

    private static func extensionOf(_ url: String) -> String {
        let clean = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let ext = (clean as NSString).pathExtension.lowercased()
        return (!ext.isEmpty && ext.count <= 4) ? ext : "jpg"
    }

    private func apiHeaders(cookie: String) -> [String: String] {
        var h = [
            "User-Agent": VideoHTTP.uaChrome,
            "Referer": Self.referer,
            "Accept": "application/json"
        ]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func mediaHeaders(cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }
}
