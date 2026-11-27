//
//  AcFunVideoParser.swift
//  YunX
//
//  AcFun 视频解析器：ajaxpipe=1 拉取 window.videoInfo，二次反转义解析 ksPlayJson 提取各画质 m3u8 直链。
//

import Foundation

public struct AcFunVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .acfun

    private static let referer = "https://www.acfun.cn/"

    public init() {}

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let url = "https://www.acfun.cn/v/ac\(link.id)?quickViewId=videoInfo_new&ajaxpipe=1"
        var headers = ["User-Agent": VideoHTTP.uaChrome, "Referer": Self.referer]
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        let html = try await VideoHTTP.getText(url: url, headers: headers, what: "AcFun 视频页")
        guard let raw = VideoHTTP.extractInlineJSON(html: html, key: "window.videoInfo") else {
            throw VideoParseError(.notFound, "AcFun 页面未找到 videoInfo（视频可能已下架）")
        }
        let unescaped = VideoHTTP.unescapeQuotes(raw.replacingOccurrences(of: "\\\\\"", with: "\\\""))
        guard let data = unescaped.data(using: .utf8),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoParseError(.unknown, "AcFun 视频信息 JSON 解析失败")
        }

        let title = VideoHTTP.str(info["title"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "acfun_\(link.id)")
        let streams = extractStreams(from: info)
        guard !streams.isEmpty else {
            throw VideoParseError(.unknown, "AcFun 未返回可用的播放流")
        }

        let medias = streams.map { stream in
            VideoMedia(
                url: stream.url,
                kind: .video,
                fileName: "\(base).mp4",
                isHls: true,
                headers: headers,
                quality: stream.label
            )
        }
        let user = info["user"] as? [String: Any]
        return VideoParseResult(
            platform: .acfun,
            title: title,
            author: VideoHTTP.str(user?["name"]),
            cover: VideoHTTP.str(info["coverUrl"]),
            text: VideoHTTP.str(info["description"]),
            url: link.url,
            medias: medias
        )
    }

    private func extractStreams(from info: [String: Any]) -> [(url: String, label: String)] {
        guard let current = info["currentVideoInfo"] as? [String: Any] else { return [] }
        let ksPlay: [String: Any]?
        if let dict = current["ksPlayJson"] as? [String: Any] {
            ksPlay = dict
        } else if let str = current["ksPlayJson"] as? String,
                  let d = str.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            ksPlay = parsed
        } else {
            ksPlay = nil
        }
        guard let adaptationSet = ksPlay?["adaptationSet"] as? [[String: Any]],
              let reps = adaptationSet.first?["representation"] as? [[String: Any]] else {
            return []
        }
        return reps.compactMap { rep in
            let url = VideoHTTP.str(rep["url"])
            guard !url.isEmpty else { return nil }
            let label = VideoHTTP.str(rep["qualityLabel"]).isEmpty ? "HLS" : VideoHTTP.str(rep["qualityLabel"])
            return (url, label)
        }
    }
}
