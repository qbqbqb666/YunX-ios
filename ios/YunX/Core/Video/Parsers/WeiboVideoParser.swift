//
//  WeiboVideoParser.swift
//  YunX
//
//  微博视频/图文解析器：支持 status（m.weibo.cn JSON）、tv（mid2id Base62 转换）与 fid 视频组件接口。
//

import Foundation

public struct WeiboVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .weibo

    private static let referer = "https://weibo.com/"

    public init() {}

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        switch link.kind {
        case "status":
            return try await parseStatus(link: link, weiboId: link.id, cookie: cookie)
        case "tv":
            return try await parseStatus(link: link, weiboId: Self.mid2id(link.id), cookie: cookie)
        case "fid":
            return try await parseFid(link: link, cookie: cookie)
        default:
            throw VideoParseError(.unsupported, "暂不支持的微博链接类型：\(link.kind)")
        }
    }

    private func parseStatus(link: DetectedVideoLink, weiboId: String, cookie: String) async throws -> VideoParseResult {
        var headers = [
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://m.weibo.cn/detail/\(weiboId)",
            "Origin": "https://m.weibo.cn",
            "X-Requested-With": "XMLHttpRequest",
            "MWeibo-Pwa": "1",
            "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "User-Agent": VideoHTTP.uaChrome
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let url = "https://m.weibo.cn/statuses/show?id=\(weiboId)&_=\(Int64(Date().timeIntervalSince1970 * 1000))"

        let resp = try await VideoHTTP.request(url: url, headers: headers, followRedirects: false)
        guard resp.statusCode == 200 else {
            try VideoHTTP.requireSuccess(resp, what: "微博正文")
            throw VideoParseError(.blocked, "微博请求被重定向或拦截（HTTP \(resp.statusCode)）")
        }
        let ct = resp.header("Content-Type") ?? ""
        guard ct.lowercased().contains("application/json") else {
            throw VideoParseError(.blocked, "微博接口触发风控验证，请稍后重试")
        }
        guard let bodyData = resp.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let data = json["data"] as? [String: Any] else {
            throw VideoParseError(.notFound, "微博内容不存在或已删除")
        }
        return buildStatusResult(link: link, data: data, cookie: cookie, allowRetweet: true)
    }

    private func parseFid(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let reqURL = "https://h5.video.weibo.com/api/component?page=/show/\(link.id)"
        var headers = [
            "Referer": "https://h5.video.weibo.com/show/\(link.id)",
            "User-Agent": VideoHTTP.uaChrome
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let payload = #"{"Component_Play_Playinfo":{"oid":"\#(link.id)"}}"#
        let text = try await VideoHTTP.postForm(url: reqURL, form: ["data": payload], headers: headers, what: "微博视频组件")
        guard let bodyData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let data = (json["data"] as? [String: Any])?["Component_Play_Playinfo"] as? [String: Any] else {
            throw VideoParseError(.notFound, "未获取到微博视频播放信息")
        }
        let mHeaders = mediaHeaders(cookie: cookie)
        let title = VideoHTTP.str(data["title"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "weibo_\(link.id)")
        var medias: [VideoMedia] = []

        if let urls = data["urls"] as? [String: Any] {
            for (label, raw) in urls {
                let u = VideoHTTP.secureURL(VideoHTTP.str(raw))
                if !u.isEmpty {
                    medias.append(VideoMedia(url: u, kind: .video, fileName: "\(base).mp4", headers: mHeaders, quality: label))
                }
            }
        }
        if medias.isEmpty {
            let fallback = VideoHTTP.secureURL(VideoHTTP.str(data["stream_url"]))
            if !fallback.isEmpty {
                medias.append(VideoMedia(url: fallback, kind: .video, fileName: "\(base).mp4", headers: mHeaders, quality: "标清"))
            }
        }
        let user = (data["reward"] as? [String: Any])?["user"] as? [String: Any]
        return VideoParseResult(
            platform: .weibo,
            title: title,
            author: VideoHTTP.str(user?["name"]),
            avatar: VideoHTTP.str(user?["profile_image_url"]),
            cover: VideoHTTP.secureURL(VideoHTTP.str(data["cover_image"])),
            text: Self.stripHTML(VideoHTTP.str(data["text"])),
            url: link.url,
            medias: medias
        )
    }

    private func buildStatusResult(
        link: DetectedVideoLink,
        data: [String: Any],
        cookie: String,
        allowRetweet: Bool
    ) -> VideoParseResult {
        let mHeaders = mediaHeaders(cookie: cookie)
        let pageInfo = data["page_info"] as? [String: Any]
        let title = VideoHTTP.str(pageInfo?["title"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "weibo_\(link.id)")
        var medias: [VideoMedia] = []

        if let urls = pageInfo?["urls"] as? [String: Any] {
            let candidates: [(String, String)] = [
                ("mp4_720p_mp4", "720P"),
                ("mp4_hd_mp4", "高清"),
                ("mp4_ld_mp4", "标清")
            ]
            for (k, label) in candidates {
                let raw = VideoHTTP.str(urls[k])
                if !raw.isEmpty {
                    medias.append(VideoMedia(
                        url: VideoHTTP.secureURL(raw),
                        kind: .video,
                        fileName: "\(base).mp4",
                        headers: mHeaders,
                        quality: label
                    ))
                    break
                }
            }
        }

        if let pics = data["pics"] as? [[String: Any]] {
            var idx = 0
            for pic in pics {
                let raw = VideoHTTP.str((pic["large"] as? [String: Any])?["url"])
                guard !raw.isEmpty else { continue }
                idx += 1
                let motion = VideoHTTP.str(pic["videoSrc"])
                medias.append(VideoMedia(
                    url: raw,
                    kind: .image,
                    fileName: "\(base)_\(idx).jpg",
                    headers: mHeaders,
                    quality: motion.isEmpty ? "原图" : "实况图",
                    motionUrl: motion
                ))
            }
        }

        if medias.isEmpty && allowRetweet, let retweet = data["retweeted_status"] as? [String: Any] {
            return buildStatusResult(link: link, data: retweet, cookie: cookie, allowRetweet: false)
        }

        let user = data["user"] as? [String: Any]
        let uid = VideoHTTP.int64(user?["id"])
        let bid = VideoHTTP.str(data["bid"])
        let cover = VideoHTTP.str((pageInfo?["page_pic"] as? [String: Any])?["url"])
        return VideoParseResult(
            platform: .weibo,
            title: title,
            author: VideoHTTP.str(user?["screen_name"]),
            avatar: VideoHTTP.str(user?["profile_image_url"]),
            cover: cover.isEmpty ? (medias.first?.url ?? "") : cover,
            text: Self.stripHTML(VideoHTTP.str(data["text"])),
            timestampSeconds: Self.parseWeiboTime(VideoHTTP.str(data["created_at"])),
            url: (uid > 0 && !bid.isEmpty) ? "https://weibo.com/\(uid)/\(bid)" : link.url,
            medias: medias
        )
    }

    /// 微博 mid → Base62 id（与 Android WeiboParser.mid2id 算法逐字符一致）
    public static func mid2id(_ mid: String) -> String {
        let reversed = String(mid.reversed())
        guard !reversed.isEmpty else { return "" }
        let chars = Array(reversed)
        let chunkCount = (chars.count + 6) / 7
        var chunks: [String] = []
        for i in 0..<chunkCount {
            let start = i * 7
            let end = min((i + 1) * 7, chars.count)
            let piece = String(chars[start..<end].reversed())
            guard let num = Int64(piece) else { return mid }
            var encoded = base62Encode(num)
            if i < chunkCount - 1 && encoded.count < 4 {
                encoded = String(repeating: "0", count: 4 - encoded.count) + encoded
            }
            chunks.append(encoded)
        }
        return chunks.reversed().joined()
    }

    private static func base62Encode(_ number: Int64) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if number == 0 { return "0" }
        var val = number
        var out: [Character] = []
        while val > 0 {
            out.append(alphabet[Int(val % 62)])
            val /= 62
        }
        return String(out.reversed())
    }

    private static func stripHTML(_ raw: String) -> String {
        let withNewlines = raw.replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
        return withNewlines.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseWeiboTime(_ raw: String) -> Int64 {
        guard !raw.isEmpty else { return 0 }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return Int64((fmt.date(from: raw)?.timeIntervalSince1970 ?? 0))
    }

    private func mediaHeaders(cookie: String) -> [String: String] {
        var h = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }
}
