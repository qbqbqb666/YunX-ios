//
//  BilibiliVideoParser.swift
//  YunX
//
//  哔哩哔哩视频解析器：支持单文件 durl 直链与登录后多画质 / DASH 分轨直链解析 + nav 登录态校验。
//

import Foundation

public struct BilibiliVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .bilibili

    private static let viewURL = "https://api.bilibili.com/x/web-interface/view"
    private static let playURL = "https://api.bilibili.com/x/player/playurl"
    private static let navURL = "https://api.bilibili.com/x/web-interface/nav"

    public init() {}

    public func validateCookie(_ cookie: String) async -> String? {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let json = try? await VideoHTTP.getJSON(url: Self.navURL, headers: apiHeaders(cookie: trimmed), what: "B站登录态校验"),
              let data = json["data"] as? [String: Any],
              (data["isLogin"] as? Bool) == true else {
            return nil
        }
        return VideoHTTP.str(data["uname"])
    }

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let query: String
        if link.id.lowercased().hasPrefix("bv") {
            query = "bvid=\(link.id)"
        } else {
            let aid = link.id.lowercased().hasPrefix("av") ? String(link.id.dropFirst(2)) : link.id
            query = "aid=\(aid)"
        }
        let view = try await VideoHTTP.getJSON(url: "\(Self.viewURL)?\(query)", headers: apiHeaders(cookie: cookie), what: "B站视频信息")
        let code = Int(VideoHTTP.int64(view["code"], default: -1))
        guard code == 0 else {
            throw VideoParseError(.notFound, "B站接口返回错误（\(code)）：\(VideoHTTP.str(view["message"]))")
        }
        guard let data = view["data"] as? [String: Any] else {
            throw VideoParseError(.unknown, "B站响应缺少视频数据")
        }
        let bvid = VideoHTTP.str(data["bvid"])
        let firstPageCid = (data["pages"] as? [[String: Any]])?.first.map { VideoHTTP.int64($0["cid"]) } ?? 0
        let cid = firstPageCid > 0 ? firstPageCid : VideoHTTP.int64(data["cid"])
        guard !bvid.isEmpty && cid > 0 else {
            throw VideoParseError(.unknown, "B站响应缺少 bvid 或 cid")
        }

        let title = VideoHTTP.str(data["title"])
        let fileBase = VideoHTTP.sanitizeFileName(title, fallback: "bilibili_\(bvid)")
        let mHeaders = apiHeaders(cookie: cookie)

        var medias: [VideoMedia] = []

        // 1. 优先取单文件 durl 直链（可直接多线程下载与原生播放）
        if let play = try? await VideoHTTP.getJSON(
            url: "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1",
            headers: mHeaders,
            what: "B站播放直链"
        ),
           let pData = play["data"] as? [String: Any],
           let durl = pData["durl"] as? [[String: Any]],
           let first = durl.first {
            let rawUrl = VideoHTTP.str(first["url"])
            if !rawUrl.isEmpty {
                let qn = Int(VideoHTTP.int64(pData["quality"]))
                medias.append(VideoMedia(
                    url: VideoHTTP.secureURL(rawUrl),
                    kind: .video,
                    fileName: "\(fileBase).mp4",
                    size: VideoHTTP.int64(first["size"], default: -1),
                    headers: mHeaders,
                    quality: Self.qualityLabel(qn)
                ))
            }
        }

        // 2. 登录态补充 DASH 高清流信息（提供高清视频轨 + 独立音轨直链）
        if !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let dashMedia = await fetchDashMedia(bvid: bvid, cid: cid, fileBase: fileBase, headers: mHeaders) {
            medias.insert(dashMedia, at: 0)
        }

        guard !medias.isEmpty else {
            throw VideoParseError(.unsupported, "未能获取到 B站 可下载视频流")
        }

        let owner = data["owner"] as? [String: Any]
        return VideoParseResult(
            platform: .bilibili,
            title: title,
            author: VideoHTTP.str(owner?["name"]),
            avatar: VideoHTTP.secureURL(VideoHTTP.str(owner?["face"])),
            cover: VideoHTTP.secureURL(VideoHTTP.str(data["pic"])),
            text: VideoHTTP.str(data["desc"]),
            timestampSeconds: VideoHTTP.int64(data["pubdate"]),
            url: "https://www.bilibili.com/video/\(bvid)",
            medias: medias
        )
    }

    private func fetchDashMedia(
        bvid: String,
        cid: Int64,
        fileBase: String,
        headers: [String: String]
    ) async -> VideoMedia? {
        guard let json = try? await VideoHTTP.getJSON(
            url: "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=120&fnval=4048&fnver=0&fourk=1",
            headers: headers,
            what: "B站 DASH 清晰度"
        ),
              let data = json["data"] as? [String: Any],
              let dash = data["dash"] as? [String: Any],
              let videos = dash["video"] as? [[String: Any]],
              let audios = dash["audio"] as? [[String: Any]] else {
            return nil
        }
        guard let bestVideo = videos.max(by: { VideoHTTP.int64($0["id"]) < VideoHTTP.int64($1["id"]) }),
              let bestAudio = audios.max(by: { VideoHTTP.int64($0["id"]) < VideoHTTP.int64($1["id"]) }) else {
            return nil
        }
        let vUrl = Self.dashURL(from: bestVideo)
        let aUrl = Self.dashURL(from: bestAudio)
        guard !vUrl.isEmpty, !aUrl.isEmpty else { return nil }
        let qn = Int(VideoHTTP.int64(bestVideo["id"]))
        return VideoMedia(
            url: vUrl,
            kind: .video,
            fileName: "\(fileBase)_\(Self.qualityLabel(qn)).mp4",
            headers: headers,
            quality: "\(Self.qualityLabel(qn)) (DASH)",
            audioUrl: aUrl,
            audioHeaders: headers
        )
    }

    private static func dashURL(from node: [String: Any]) -> String {
        let a = VideoHTTP.str(node["baseUrl"])
        let b = VideoHTTP.str(node["base_url"])
        let chosen = a.isEmpty ? b : a
        return chosen.isEmpty ? "" : VideoHTTP.secureURL(chosen)
    }

    public static func qualityLabel(_ qn: Int) -> String {
        switch qn {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        default: return qn > 0 ? "\(qn)P" : "标清"
        }
    }

    private func apiHeaders(cookie: String) -> [String: String] {
        var h = [
            "User-Agent": VideoHTTP.uaChrome,
            "Referer": "https://www.bilibili.com/"
        ]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }
}
