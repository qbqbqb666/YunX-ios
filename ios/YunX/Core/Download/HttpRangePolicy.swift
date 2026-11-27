//
//  HttpRangePolicy.swift
//  YunX
//
//  HTTP Content-Range 解析与严格匹配校验（与 Android HttpRangePolicy.kt 一致）。
//

import Foundation

public enum HttpRangePolicy {
    public struct ContentRange: Equatable, Sendable {
        public let start: Int64
        public let end: Int64
        public let total: Int64?

        public init(start: Int64, end: Int64, total: Int64?) {
            self.start = start
            self.end = end
            self.total = total
        }
    }

    public static func parse(_ value: String?) -> ContentRange? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: #"^bytes\s+(\d+)-(\d+)/(\d+|\*)$"#, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, options: [], range: nsRange),
              match.numberOfRanges == 4,
              let r1 = Range(match.range(at: 1), in: raw),
              let r2 = Range(match.range(at: 2), in: raw),
              let r3 = Range(match.range(at: 3), in: raw),
              let start = Int64(raw[r1]),
              let end = Int64(raw[r2]) else {
            return nil
        }
        let totalStr = String(raw[r3])
        let total: Int64? = totalStr == "*" ? nil : Int64(totalStr)
        if start < 0 || end < start { return nil }
        if let total, end >= total { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    public static func matches(_ value: String?, requestedStart: Int64, requestedEnd: Int64?) -> Bool {
        guard let parsed = parse(value) else { return false }
        guard parsed.start == requestedStart else { return false }
        if let requestedEnd {
            return parsed.end == requestedEnd
        }
        return true
    }

    /// 识别服务端返回的防盗链/广告/错误 HTML 页，避免被当成文件落盘
    public static func isHtmlResponse(contentType: String?) -> Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return ct.contains("text/html")
    }
}
