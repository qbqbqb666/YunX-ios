//
//  LanzouConstants.swift
//  YunX
//
//  蓝奏云全域名族常量与 URL 规范化（含 2026 新域名族 lanzn）。
//

import Foundation

public enum LanzouConstants {
    public static let webUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    public static let downIPCookie = "down_ip=1"

    public static func isLanzouHost(_ host: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)$"#,
            options: [.caseInsensitive]
        ) else {
            return false
        }
        let range = NSRange(host.startIndex..<host.endIndex, in: host)
        return regex.firstMatch(in: host, options: [], range: range) != nil
    }

    public static func normalizeShareURL(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if u.lowercased().hasPrefix("http://") {
            u = "https://" + u.dropFirst(7)
        }
        if let hash = u.firstIndex(of: "#") {
            u = String(u[..<hash])
        }
        while u.hasSuffix("/") {
            u.removeLast()
        }
        return u
    }
}
