//
//  KuaishouVideoParser.swift
//  YunX
//
//  快手视频/图集解析器：iOS UA 跟随入口页跳转并从 window.INIT_STATE 提取视频与图集直链。
//

import Foundation

public struct KuaishouVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .kuaishou

    private static let defaultReferer = "https://v.kuaishou.com/"

    public init() {}

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers = [
            "User-Agent": VideoHTTP.uaIPhone,
            "Referer": Self.defaultReferer
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        let normalized = link.url.lowercased().hasPrefix("http") ? link.url : "https://\(link.url)"
        let redirected = await VideoHTTP.expandRedirect(url: normalized, headers: headers) ?? normalized
        let pageURL = redirected.replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")

        let resp = try await VideoHTTP.request(url: pageURL, headers: headers)
        try VideoHTTP.requireSuccess(resp, what: "快手作品页")
        guard let initRaw = VideoHTTP.extractInlineJSON(html: resp.body, key: "window.INIT_STATE"),
              let initData = initRaw.data(using: .utf8),
              let initState = try? JSONSerialization.jsonObject(with: initData) as? [String: Any] else {
            throw VideoParseError(.unknown, "快手页面未返回 window.INIT_STATE 数据")
        }

        var photo: [String: Any]?
        for (_, val) in initState {
            if let dict = val as? [String: Any], let p = dict["photo"] as? [String: Any] {
                photo = p
                break
            }
        }
        guard let photo else {
            throw VideoParseError(.notFound, "未找到快手作品内容（可能已删除）")
        }

        let title = VideoHTTP.str(photo["caption"])
        let fallbackId = link.id.isEmpty ? String(Int64(Date().timeIntervalSince1970), radix: 36) : link.id
        let base = VideoHTTP.sanitizeFileName(title, fallback: "kuaishou_\(fallbackId)")

        var medias: [VideoMedia] = []
        if let videoURL = firstURL(photo["mainMvUrls"] as? [[String: Any]]) {
            medias.append(VideoMedia(
                url: videoURL,
                kind: .video,
                fileName: "\(base).mp4",
                headers: headers,
                quality: "原画"
            ))
        }
        let atlas = (photo["ext_params"] as? [String: Any])?["atlas"] as? [String: Any]
        for (idx, imgURL) in atlasImageURLs(atlas).enumerated() {
            medias.append(VideoMedia(
                url: imgURL,
                kind: .image,
                fileName: "\(base)_\(idx + 1).jpg",
                headers: headers,
                quality: "原图"
            ))
        }
        guard !medias.isEmpty else {
            throw VideoParseError(.notFound, "快手作品未包含可下载的视频或图集")
        }

        let author = VideoHTTP.str(photo["userName"]).replacingOccurrences(of: "\u{3164}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return VideoParseResult(
            platform: .kuaishou,
            title: title,
            author: author,
            avatar: VideoHTTP.str(photo["headUrl"]),
            cover: firstURL(photo["coverUrls"] as? [[String: Any]]) ?? (medias.first?.url ?? ""),
            text: title,
            timestampSeconds: VideoHTTP.int64(photo["timestamp"]) / 1000,
            url: link.url,
            medias: medias
        )
    }

    private func firstURL(_ nodes: [[String: Any]]?) -> String? {
        guard let nodes else { return nil }
        for item in nodes {
            let u = VideoHTTP.str(item["url"])
            if !u.isEmpty { return u }
        }
        return nil
    }

    private func atlasImageURLs(_ atlas: [String: Any]?) -> [String] {
        guard let atlas,
              let cdnList = atlas["cdnList"] as? [[String: Any]],
              let cdn = cdnList.first.map({ VideoHTTP.str($0["cdn"]) }),
              !cdn.isEmpty,
              let routes = atlas["list"] as? [String] else {
            return []
        }
        return routes.filter { !$0.isEmpty }.map { route in
            let clean = route.hasPrefix("/") ? String(route.dropFirst()) : route
            return "https://\(cdn)/\(clean)"
        }
    }
}
