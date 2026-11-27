//
//  VideoParseService.swift
//  YunX
//
//  视频解析总调度服务：链接识别 → 最多 5 跳短链展开 → 读取对应视频平台 Cookie → 分发解析器 → HTTPS 归一化。
//

import Foundation

@MainActor
public final class VideoParseService {
    private let accountStore: VideoAccountStore
    private let parsers: [VideoPlatform: VideoParser]

    public init(accountStore: VideoAccountStore) {
        self.accountStore = accountStore
        let all: [VideoParser] = [
            DouyinVideoParser(),
            KuaishouVideoParser(),
            WeiboVideoParser(),
            AcFunVideoParser(),
            BilibiliVideoParser(),
            XhsVideoParser(),
            PixivVideoParser()
        ]
        var map: [VideoPlatform: VideoParser] = [:]
        for p in all { map[p.platform] = p }
        self.parsers = map
    }

    public func parser(for platform: VideoPlatform) -> VideoParser? {
        parsers[platform]
    }

    public func parse(text: String) async throws -> VideoParseResult {
        guard let detected = VideoLinkParser.parse(text) else {
            throw VideoParseError(.unsupported, "无法识别该视频平台链接，当前支持抖音 / 小红书 / 快手 / 微博 / B站 / AcFun / Pixiv")
        }
        return try await parse(link: detected)
    }

    public func parse(link: DetectedVideoLink) async throws -> VideoParseResult {
        let resolved = link.isShortLink ? await expandShortLink(link) : link
        guard let parser = parsers[resolved.platform] else {
            throw VideoParseError(.unsupported, "暂不支持 \(resolved.platform.displayName) 视频解析")
        }
        let cookie = accountStore.cookie(for: resolved.platform) ?? ""
        let result = try await parser.parse(link: resolved, cookie: cookie)
        return result.withSecureURLs()
    }

    private func expandShortLink(_ link: DetectedVideoLink) async -> DetectedVideoLink {
        var current = link
        for _ in 0..<5 {
            let ua = (current.platform == .douyin || current.platform == .kuaishou)
                ? VideoHTTP.uaIPhone
                : VideoHTTP.uaChrome
            guard let next = await VideoHTTP.expandRedirect(url: current.url, headers: ["User-Agent": ua]) else {
                return current
            }
            guard let reparsed = VideoLinkParser.parse(next) else {
                return DetectedVideoLink(platform: current.platform, kind: current.kind, id: current.id, url: next, isShortLink: false)
            }
            if !reparsed.isShortLink {
                return reparsed
            }
            current = reparsed
        }
        return current
    }
}
