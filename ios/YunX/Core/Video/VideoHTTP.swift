//
//  VideoHTTP.swift
//  YunX
//
//  视频解析公共 HTTP 工具：状态码转错误分类、短链展开、内嵌 JSON 抽取、HTTPS 归一化与文件名清洗。
//

import Foundation

public struct VideoRawResponse: Sendable {
    public let statusCode: Int
    public let body: String
    public let headers: [String: String]
    public let setCookies: [String]
    public let finalURL: String

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }
}

public enum VideoHTTP {
    public static let uaChrome =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    public static let uaIPhone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    public static func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true,
        http: HTTPClient = .shared
    ) async throws -> VideoRawResponse {
        do {
            let resp = try await http.send(
                url: url,
                method: method,
                headers: headers,
                body: body,
                followRedirects: followRedirects
            )
            return VideoRawResponse(
                statusCode: resp.statusCode,
                body: resp.text,
                headers: resp.headers,
                setCookies: resp.setCookies,
                finalURL: resp.finalURL?.absoluteString ?? url
            )
        } catch {
            throw VideoParseError(.network, "网络请求失败：\(error.localizedDescription)")
        }
    }

    public static func requireSuccess(_ response: VideoRawResponse, what: String) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        switch response.statusCode {
        case 403, 418, 429:
            throw VideoParseError(.blocked, "\(what)被平台风控拦截（HTTP \(response.statusCode)），请稍后重试或登录账号")
        case 404, 410:
            throw VideoParseError(.notFound, "\(what)不存在或已删除（HTTP \(response.statusCode)）")
        default:
            throw VideoParseError(.unknown, "\(what)失败（HTTP \(response.statusCode)）")
        }
    }

    public static func getText(
        url: String,
        headers: [String: String] = [:],
        what: String = "解析",
        http: HTTPClient = .shared
    ) async throws -> String {
        let resp = try await request(url: url, headers: headers, http: http)
        try requireSuccess(resp, what: what)
        return resp.body
    }

    public static func getJSON(
        url: String,
        headers: [String: String] = [:],
        what: String = "解析",
        http: HTTPClient = .shared
    ) async throws -> [String: Any] {
        let text = try await getText(url: url, headers: headers, what: what, http: http)
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoParseError(.unknown, "\(what)响应不是合法 JSON")
        }
        return json
    }

    public static func postForm(
        url: String,
        form: [String: String],
        headers: [String: String] = [:],
        what: String = "解析",
        http: HTTPClient = .shared
    ) async throws -> String {
        let encoded = form.map { k, v in
            "\(UploadSigning.rfc3986Escape(k))=\(UploadSigning.rfc3986Escape(v))"
        }.joined(separator: "&")
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        let resp = try await request(url: url, method: "POST", headers: merged, body: Data(encoded.utf8), http: http)
        try requireSuccess(resp, what: what)
        return resp.body
    }

    public static func expandRedirect(
        url: String,
        headers: [String: String] = [:],
        http: HTTPClient = .shared
    ) async -> String? {
        guard let resp = try? await request(url: url, headers: headers, followRedirects: false, http: http) else {
            return nil
        }
        if (300..<400).contains(resp.statusCode), let location = resp.header("Location"), !location.isEmpty {
            if let base = URL(string: url), let resolved = URL(string: location, relativeTo: base)?.absoluteString {
                return resolved
            }
            return location
        }
        return resp.finalURL != url ? resp.finalURL : nil
    }

    /// 从 HTML 中提取形如 `window.XXX = {...}</script>` 的内嵌 JSON
    public static func extractInlineJSON(html: String, key: String, stopAt: String = "</script>") -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let escapedStop = NSRegularExpression.escapedPattern(for: stopAt)
        let pattern = "\(escapedKey)\\s*=\\s*(.*?)\(escapedStop)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let inner = Range(match.range(at: 1), in: html) else {
            return nil
        }
        var raw = String(html[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasSuffix(";") {
            raw.removeLast()
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    public static func unescapeQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\/", with: "/")
    }

    public static func secureURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return "https:\(trimmed)" }
        if trimmed.hasPrefix("http://") { return "https://" + trimmed.dropFirst("http://".count) }
        return trimmed
    }

    public static func sanitizeFileName(_ raw: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated.isEmpty ? fallback : truncated
    }

    public static func str(_ any: Any?) -> String {
        if let s = any as? String, s != "null" { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    public static func int64(_ any: Any?, default def: Int64 = 0) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let v = Int64(s) { return v }
        return def
    }
}
