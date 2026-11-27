//
//  GitHubLinkParser.swift
//  YunX
//
//  GitHub 链接类型识别器（与 Android GitHubLinkParser.kt 完全一致）：
//  优先级 DirectFile > Repository > Account。
//

import Foundation

public enum GitHubLinkType: Equatable, Sendable {
    case repository(owner: String, repo: String, subPath: String?)
    case account(owner: String)
    case directFile(url: String, fileName: String)
}

public enum GitHubLinkParser {
    private static let specialPaths: Set<String> = [
        "features", "topics", "trending", "collections", "events", "sponsors",
        "about", "pricing", "login", "signup", "join", "marketplace", "explore",
        "notifications", "settings", "new", "orgs", "sites", "customer-stories",
        "team", "enterprise", "readme", "contact", "security", "resources"
    ]

    public static func parse(_ text: String) -> GitHubLinkType? {
        guard let rawURL = firstMatch(#"https?://[^\s]+"#, in: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let url = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: "。，,;；)]}\"'"))

        // 1) 文件直链（raw.githubusercontent.com / releases/download / github.com/.../raw/...）
        let directPatterns = [
            #"raw\.githubusercontent\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/[^/]+/(.+)"#,
            #"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/[^/]+/(.+)"#,
            #"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/raw/[^/]+/(.+)"#
        ]
        for pattern in directPatterns {
            let groups = captureGroups(pattern, in: url)
            if groups.count >= 4, let name = fileNameOf(groups[3]) {
                return .directFile(url: url, fileName: name)
            }
        }

        // 2) 仓库链接
        let repoGroups = captureGroups(#"github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(?:/(.*))?"#, in: url)
        if repoGroups.count >= 3 {
            let owner = repoGroups[1]
            if specialPaths.contains(owner.lowercased()) { return nil }
            var repo = repoGroups[2]
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            let rawSub = repoGroups.count >= 4 ? repoGroups[3] : ""
            let cleanSub = rawSub
                .split(separator: "?", maxSplits: 1).first
                .flatMap { $0.split(separator: "#", maxSplits: 1).first }
                .map(String.init) ?? ""
            return .repository(owner: owner, repo: repo, subPath: cleanSub.isEmpty ? nil : cleanSub)
        }

        // 3) 账号 / 组织主页
        let accGroups = captureGroups(#"github\.com/([A-Za-z0-9_.-]+)/?(?:[?#]|$)"#, in: url)
        if accGroups.count >= 2 {
            let owner = accGroups[1]
            if specialPaths.contains(owner.lowercased()) { return nil }
            return .account(owner: owner)
        }

        return nil
    }

    private static func fileNameOf(_ path: String) -> String? {
        let clean = path
            .split(separator: "?", maxSplits: 1).first
            .flatMap { $0.split(separator: "#", maxSplits: 1).first }
            .map(String.init) ?? ""
        let name = clean.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func captureGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return []
        }
        return (0..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
