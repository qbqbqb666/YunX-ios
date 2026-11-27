//
//  ShareLinkParser.swift
//  YunX
//
//  全 11 平台网盘分享链接与提取码统一识别器（与 Android ShareLinkParser.kt 1:1 规则对齐）。
//

import Foundation

public enum ShareLinkParser {
    private static let trailingTrimSet = CharacterSet(charactersIn: "。，,;；)]}\"'》】")

    public static func parse(_ text: String) -> ParsedShare? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var url = firstMatch(pattern: #"https?://[^\s]+"#, in: trimmed) else {
            return nil
        }
        url = url.trimmingCharacters(in: trailingTrimSet)

        // 1. 夸克
        if let sid = firstCapture(pattern: #"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractPwd(url: url, text: trimmed), platform: .quark, rawUrl: url)
        }
        // 2. UC
        if let sid = firstCapture(pattern: #"drive\.uc\.cn/s/([A-Za-z0-9]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractPwd(url: url, text: trimmed), platform: .uc, rawUrl: url)
        }
        // 3. 迅雷
        if let sid = firstCapture(pattern: #"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractPwd(url: url, text: trimmed), platform: .xunlei, rawUrl: url)
        }
        // 4. 百度（surl 去掉开头 "1"）
        if let sid = firstCapture(pattern: #"pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)"#, in: url) {
            let surl = sid.hasPrefix("1") ? String(sid.dropFirst()) : sid
            return ParsedShare(shareId: surl, pwd: extractPwd(url: url, text: trimmed), platform: .baidu, rawUrl: url)
        }
        // 5. 139（和彩云）
        if let sid = firstCapture(pattern: #"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractPwd(url: url, text: trimmed), platform: .c139, rawUrl: url)
        }
        // 6. 123 云盘（3 种形态按优先级匹配）
        if let sid = firstCapture(pattern: #"123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#, in: url)
            ?? firstCapture(pattern: #"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#, in: url)
            ?? firstCapture(pattern: #"api/srr\?sk=([A-Za-z0-9-]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractPwd(url: url, text: trimmed), platform: .pan123, rawUrl: url)
        }
        // 7. 115 网盘
        if let sid = firstCapture(pattern: #"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#, in: url) {
            let pwd = firstCapture(pattern: #"[?&]password=([A-Za-z0-9]+)"#, in: url)
                ?? extractPwdFromText(trimmed)
            return ParsedShare(shareId: sid, pwd: pwd, platform: .pan115, rawUrl: url)
        }
        if let captures = allCaptures(pattern: #"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, in: url),
           captures.count >= 2 {
            return ParsedShare(shareId: captures[0], pwd: captures[1], platform: .pan115, rawUrl: url)
        }
        // 8. 光鸭云盘
        if let sid = firstCapture(pattern: #"guangyapan\.com/s/([A-Za-z0-9_-]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractPwd(url: url, text: trimmed), platform: .guangya, rawUrl: url)
        }
        // 9. 蓝奏云优享版（必须先于蓝奏云，防止 ilanzou 被误判）
        if let sid = firstCapture(pattern: #"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractLanzouPwd(url: url, text: trimmed), platform: .ilanzou, rawUrl: url)
        }
        // 10. 蓝奏云（全域名族，含 2026 新族 lanzn）
        if let sid = firstCapture(pattern: #"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)/([A-Za-z0-9]+)"#, in: url) {
            return ParsedShare(shareId: sid, pwd: extractLanzouPwd(url: url, text: trimmed), platform: .lanzou, rawUrl: url)
        }
        // 11. GitHub（支持仓库 / Releases / raw 直链 / 账号主页，排除功能页路径）
        if let gh = GitHubLinkParser.parse(url) {
            let sid: String
            switch gh {
            case .repository(let owner, let repo, _): sid = "\(owner)/\(repo)"
            case .account(let owner): sid = owner
            case .directFile(_, let fileName): sid = fileName
            }
            return ParsedShare(shareId: sid, pwd: nil, platform: .github, rawUrl: url)
        }
        return nil
    }

    private static func extractPwd(url: String, text: String) -> String? {
        firstCapture(pattern: #"[?&]pwd=([A-Za-z0-9]+)"#, in: url)
            ?? extractPwdFromText(text)
    }

    private static func extractLanzouPwd(url: String, text: String) -> String? {
        firstCapture(pattern: #"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#, in: url)
            ?? extractPwdFromText(text)
    }

    private static func extractPwdFromText(_ text: String) -> String? {
        firstCapture(pattern: #"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#, in: text)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let r = Range(match.range, in: text) else {
            return nil
        }
        return String(text[r])
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        allCaptures(pattern: pattern, in: text)?.first
    }

    private static func allCaptures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        var results: [String] = []
        for idx in 1..<match.numberOfRanges {
            let nsRange = match.range(at: idx)
            if nsRange.location != NSNotFound, let r = Range(nsRange, in: text) {
                results.append(String(text[r]))
            }
        }
        return results
    }
}
