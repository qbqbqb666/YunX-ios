//
//  XhsVideoParser.swift
//  YunX
//
//  小红书图文/视频笔记解析器（explore + discovery 双路径、去水印原图换算与并行 HEAD 探测回退）。
//

import Foundation

public struct XhsVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .xhs

    private static let xhsHome = "https://www.xiaohongshu.com"
    private static let imageCDN = "https://sns-img-bd.xhscdn.com"
    private static let loginWallMarkers = ["/login", "website-login", "captcha"]
    private static let streamOrder: [(key: String, label: String)] = [
        ("h265", "H.265"),
        ("h264", "H.264"),
        ("av1", "AV1"),
        ("h266", "H.266")
    ]
    private static let acceptHeader =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"

    public init() {}

    public func validateCookie(_ cookie: String) async -> String? {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let resp = try? await VideoHTTP.request(url: "\(Self.xhsHome)/explore", headers: exploreHeaders(cookie: trimmed)) else {
            return nil
        }
        if Self.loginWallMarkers.contains(where: { resp.finalURL.contains($0) }) {
            return nil
        }
        return ""
    }

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            return try await parseExplore(link: link, cookie: cookie)
        } catch let err as VideoParseError where err.kind == .unsupported {
            throw err
        } catch let firstErr {
            do {
                return try await parseDiscovery(link: link, cookie: cookie)
            } catch let secondErr as VideoParseError {
                throw secondErr
            } catch {
                throw (firstErr as? VideoParseError) ?? VideoParseError(.unknown, "小红书笔记解析失败")
            }
        }
    }

    private func parseExplore(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let html = try await fetchPage(url: "\(Self.xhsHome)/explore/\(link.id)\(querySuffix(link))", headers: exploreHeaders(cookie: cookie))
        let state = try extractInitialState(html)
        guard let note = ((state["note"] as? [String: Any])?["noteDetailMap"] as? [String: Any])?[link.id] as? [String: Any],
              let detail = note["note"] as? [String: Any] else {
            throw VideoParseError(.notFound, "未找到小红书笔记详情（可能已删除或设为私密）")
        }
        let mHeaders = mediaHeaders(cookie: cookie)
        let title = VideoHTTP.str(detail["title"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "xhs_\(link.id)")
        let rawImages = (detail["imageList"] as? [[String: Any]] ?? []).compactMap { Self.rawImageURL($0) }

        var medias: [VideoMedia] = []
        var cover = ""
        var notice = ""

        if let picked = pickVideo(detail) {
            cover = Self.watermarkFreeOrRaw(rawImages.first ?? "")
            medias.append(VideoMedia(url: picked.url, kind: .video, fileName: "\(base).mp4", headers: mHeaders, quality: picked.label))
        } else if detail["video"] is [String: Any] {
            throw VideoParseError(.unknown, "检测到视频笔记但未提取到视频流")
        } else {
            let (urls, fallbackCount) = await resolveImages(rawImages, headers: mHeaders)
            for (idx, u) in urls.enumerated() {
                medias.append(VideoMedia(url: u, kind: .image, fileName: "\(base)_\(idx + 1).jpg", headers: mHeaders, quality: "原图"))
            }
            if fallbackCount > 0 {
                notice = "有 \(fallbackCount) 张原图节点不可用，已自动回退至平台图床地址"
            }
        }

        let user = detail["user"] as? [String: Any]
        return VideoParseResult(
            platform: .xhs,
            title: title,
            author: VideoHTTP.str(user?["nickname"]),
            avatar: VideoHTTP.str(user?["avatar"]),
            cover: cover.isEmpty ? (medias.first?.url ?? "") : cover,
            text: VideoHTTP.str(detail["desc"]),
            timestampSeconds: VideoHTTP.int64(detail["time"]) / 1000,
            url: link.url,
            medias: medias,
            notice: notice
        )
    }

    private func parseDiscovery(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let html = try await fetchPage(url: "\(Self.xhsHome)/discovery/item/\(link.id)\(querySuffix(link))", headers: discoveryHeaders(cookie: cookie))
        let state = try extractInitialState(html)
        guard let noteRoot = state["noteData"] as? [String: Any],
              let dataNode = noteRoot["data"] as? [String: Any],
              let detail = dataNode["noteData"] as? [String: Any] else {
            throw VideoParseError(.notFound, "小红书笔记已失效或删除")
        }
        let mHeaders = mediaHeaders(cookie: cookie)
        let title = VideoHTTP.str(detail["title"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "xhs_\(link.id)")
        let rawImages = (detail["imageList"] as? [[String: Any]] ?? []).compactMap { Self.rawImageURL($0) }
        let preloadImages = ((noteRoot["normalNotePreloadData"] as? [String: Any])?["imagesList"] as? [[String: Any]] ?? []).compactMap { item -> String? in
            let lg = VideoHTTP.str(item["urlSizeLarge"])
            let u = lg.isEmpty ? VideoHTTP.str(item["url"]) : lg
            return u.isEmpty ? nil : u
        }

        var medias: [VideoMedia] = []
        var cover = ""
        var notice = ""

        if let picked = pickVideo(detail) {
            cover = Self.watermarkFreeOrRaw((preloadImages.isEmpty ? rawImages : preloadImages).first ?? "")
            medias.append(VideoMedia(url: picked.url, kind: .video, fileName: "\(base).mp4", headers: mHeaders, quality: picked.label))
        } else {
            let (urls, fallbackCount) = await resolveImages(rawImages, headers: mHeaders)
            for (idx, u) in urls.enumerated() {
                medias.append(VideoMedia(url: u, kind: .image, fileName: "\(base)_\(idx + 1).jpg", headers: mHeaders, quality: "原图"))
            }
            if fallbackCount > 0 {
                notice = "有 \(fallbackCount) 张原图节点不可用，已自动回退至平台图床地址"
            }
        }

        let user = detail["user"] as? [String: Any]
        return VideoParseResult(
            platform: .xhs,
            title: title,
            author: VideoHTTP.str(user?["nickName"]),
            avatar: VideoHTTP.str(user?["avatar"]),
            cover: cover.isEmpty ? (medias.first?.url ?? "") : cover,
            text: VideoHTTP.str(detail["desc"]),
            timestampSeconds: VideoHTTP.int64(detail["time"]) / 1000,
            url: link.url,
            medias: medias,
            notice: notice
        )
    }

    private func fetchPage(url: String, headers: [String: String]) async throws -> String {
        let resp = try await VideoHTTP.request(url: url, headers: headers)
        try VideoHTTP.requireSuccess(resp, what: "小红书笔记页")
        if Self.loginWallMarkers.contains(where: { resp.finalURL.contains($0) }) {
            throw VideoParseError(.unsupported, "小红书需要登录账号后才能解析，请先在「账号」页登录小红书")
        }
        return resp.body
    }

    private func extractInitialState(_ html: String) throws -> [String: Any] {
        guard let raw = VideoHTTP.extractInlineJSON(html: html, key: "window.__INITIAL_STATE__") else {
            throw VideoParseError(.unknown, "未在小红书页面中找到 __INITIAL_STATE__ 数据")
        }
        let sanitized = raw.replacingOccurrences(of: "undefined", with: "null")
        guard let data = sanitized.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoParseError(.unknown, "小红书页面状态数据解析失败")
        }
        return json
    }

    private func pickVideo(_ note: [String: Any]) -> (url: String, label: String)? {
        guard let video = note["video"] as? [String: Any],
              let media = video["media"] as? [String: Any],
              let stream = media["stream"] as? [String: Any] else {
            return nil
        }
        for (key, label) in Self.streamOrder {
            guard let arr = stream[key] as? [[String: Any]], let first = arr.first else { continue }
            let m1 = VideoHTTP.str(first["masterUrl"])
            let m2 = VideoHTTP.str(first["master_url"])
            let chosen = m1.isEmpty ? m2 : m1
            if !chosen.isEmpty {
                return (chosen, label)
            }
        }
        return nil
    }

    private func resolveImages(_ rawItems: [String], headers: [String: String]) async -> ([String], Int) {
        guard !rawItems.isEmpty else { return ([], 0) }
        return await withTaskGroup(of: (Int, String, Bool).self) { group in
            for (idx, raw) in rawItems.enumerated() {
                group.addTask {
                    let clean = Self.watermarkFreeOrRaw(raw)
                    if clean == raw { return (idx, raw, false) }
                    if let resp = try? await VideoHTTP.request(url: clean, method: "HEAD", headers: headers),
                       resp.statusCode == 404 || resp.statusCode == 410 {
                        return (idx, raw, true)
                    }
                    return (idx, clean, false)
                }
            }
            var pairs = [(Int, String, Bool)]()
            for await item in group { pairs.append(item) }
            pairs.sort { $0.0 < $1.0 }
            return (pairs.map(\.1), pairs.filter(\.2).count)
        }
    }

    public static func watermarkFreeOrRaw(_ raw: String) -> String {
        guard !raw.isEmpty,
              let schemeRange = raw.range(of: "://") else { return raw }
        let afterScheme = raw[schemeRange.upperBound...]
        guard let slashIdx = afterScheme.firstIndex(of: "/") else { return raw }
        let pathParts = afterScheme[afterScheme.index(after: slashIdx)...].split(separator: "/", omittingEmptySubsequences: false)
        guard pathParts.count > 2 else { return raw }
        let joined = pathParts.dropFirst(2).joined(separator: "/")
        let imageId = joined.split(separator: "!", maxSplits: 1).first.map(String.init) ?? ""
        return imageId.isEmpty ? raw : "\(Self.imageCDN)/\(imageId)"
    }

    private static func rawImageURL(_ item: [String: Any]) -> String? {
        let a = VideoHTTP.str(item["urlDefault"])
        let b = VideoHTTP.str(item["url"])
        let u = a.isEmpty ? b : a
        return u.isEmpty ? nil : u
    }

    private func querySuffix(_ link: DetectedVideoLink) -> String {
        guard let qIdx = link.url.firstIndex(of: "?") else { return "" }
        return String(link.url[qIdx...])
    }

    private func exploreHeaders(cookie: String) -> [String: String] {
        var h = [
            "User-Agent": VideoHTTP.uaChrome,
            "Accept": Self.acceptHeader,
            "Referer": "\(Self.xhsHome)/"
        ]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func discoveryHeaders(cookie: String) -> [String: String] {
        var h = [
            "User-Agent": VideoHTTP.uaIPhone,
            "Accept": Self.acceptHeader,
            "Referer": "\(Self.xhsHome)/",
            "Origin": Self.xhsHome,
            "X-Requested-With": "XMLHttpRequest",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty"
        ]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func mediaHeaders(cookie: String) -> [String: String] {
        var h = [
            "User-Agent": VideoHTTP.uaChrome,
            "Referer": "\(Self.xhsHome)/"
        ]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }
}
