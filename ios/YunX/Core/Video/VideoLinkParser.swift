//
//  VideoLinkParser.swift
//  YunX
//
//  全 7 大视频/图文平台链接识别器（与 Android VideoLinkParser.kt 正则优先级 1:1 对齐）。
//

import Foundation

public enum VideoLinkParser {
    private struct Rule {
        let platform: VideoPlatform
        let kind: String
        let regex: NSRegularExpression
    }

    private static let trailingTrimSet = CharacterSet(charactersIn: "。，,；;)]}\"'、！？…")

    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)

    private static let rules: [Rule] = {
        let defs: [(VideoPlatform, String, String)] = [
            // 抖音
            (.douyin, "short", #"v\.douyin\.com/[A-Za-z0-9_\-]+"#),
            (.douyin, "short", #"jx\.douyin\.com/[A-Za-z0-9_\-]+"#),
            (.douyin, "video", #"(?:www\.)?douyin\.com/(video|note)/(\d{10,})"#),
            (.douyin, "video", #"douyin\.com/[^\s]*[?&]modal_id=(\d{10,})"#),
            (.douyin, "video", #"iesdouyin\.com/share/(?:slides|video|note)/(\d{10,})"#),
            (.douyin, "video", #"m\.douyin\.com/share/(?:slides|video|note)/(\d{10,})"#),
            (.douyin, "video", #"jingxuan\.douyin\.com/m/(?:slides|video|note)/(\d{10,})"#),
            // 小红书
            (.xhs, "short", #"xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+"#),
            (.xhs, "note", #"xiaohongshu\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})"#),
            // 快手
            (.kuaishou, "short", #"v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+"#),
            (.kuaishou, "photo", #"(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\d]+)"#),
            (.kuaishou, "photo", #"(?:www\.)?kuaishou\.com/f/([A-Za-z\d]+)"#),
            (.kuaishou, "photo", #"(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)"#),
            // 微博
            (.weibo, "tv", #"weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)"#),
            (.weibo, "fid", #"video\.weibo\.com/show\?fid=(\d+:\d+)"#),
            (.weibo, "status", #"weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)"#),
            (.weibo, "status", #"weibo\.com/\d+/([0-9a-zA-Z]{6,})"#),
            // AcFun
            (.acfun, "ac", #"acfun\.cn/.*(?:ac=|/ac)(\d+)"#),
            // 哔哩哔哩
            (.bilibili, "short", #"b23\.tv/[A-Za-z\d]+"#),
            (.bilibili, "short", #"bili2233\.cn/[A-Za-z\d]+"#),
            (.bilibili, "video", #"bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)"#),
            // Pixiv
            (.pixiv, "artwork", #"pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)"#),
            (.pixiv, "artwork", #"pixiv\.net/member_illust\.php\?[^\s]*illust_id=(\d+)"#)
        ]
        return defs.map {
            Rule(platform: $0.0, kind: $0.1, regex: try! NSRegularExpression(pattern: $0.2, options: [.caseInsensitive]))
        }
    }()

    public static func parse(_ text: String) -> DetectedVideoLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        guard let urlMatch = urlRegex.firstMatch(in: trimmed, range: fullRange),
              let urlSwiftRange = Range(urlMatch.range, in: trimmed) else {
            return nil
        }
        let rawURL = String(trimmed[urlSwiftRange]).trimmingCharacters(in: trailingTrimSet)
        let urlRange = NSRange(rawURL.startIndex..., in: rawURL)

        for rule in rules {
            guard let m = rule.regex.firstMatch(in: rawURL, range: urlRange) else { continue }
            var extractedId = ""
            if m.numberOfRanges > 1 {
                for idx in stride(from: m.numberOfRanges - 1, through: 1, by: -1) {
                    let r = m.range(at: idx)
                    if r.location != NSNotFound, let sr = Range(r, in: rawURL) {
                        let candidate = String(rawURL[sr])
                        if !candidate.isEmpty {
                            extractedId = candidate
                            break
                        }
                    }
                }
            }
            let isShort = (rule.kind == "short")
            let normalizedURL = rawURL.lowercased().hasPrefix("http") ? rawURL : "https://\(rawURL)"
            return DetectedVideoLink(
                platform: rule.platform,
                kind: isShort ? "short" : rule.kind,
                id: isShort ? "" : extractedId,
                url: normalizedURL,
                isShortLink: isShort
            )
        }
        return nil
    }

    public static func looksLikeVideoLink(_ text: String) -> Bool {
        parse(text) != nil
    }
}
