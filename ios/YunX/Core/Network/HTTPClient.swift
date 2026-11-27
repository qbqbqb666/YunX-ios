//
//  HTTPClient.swift
//  YunX
//
//  统一 HTTP 客户端工厂：隔离 API / 下载 / 禁重定向三种会话，
//  所有会话显式关闭 URLSession 自动 Cookie 罐，确保多账号与游客态 __pugs 绝对不串号。
//

import Foundation

public struct ParsedHTTPCookie: Sendable {
    public let name: String
    public let value: String
    public let path: String

    public var pair: String { "\(name)=\(value)" }
}

public struct HTTPResponseData: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let setCookies: [String]
    public let parsedCookies: [ParsedHTTPCookie]
    public let body: Data
    public let finalURL: URL?

    public var isSuccessful: Bool { (200..<300).contains(statusCode) }

    public var text: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }

    /// 提取路径绑定 Cookie（例如 115 下载直链响应下发的非根路径 900s CDN Cookie，避开全局 acw_tc）
    public func extractPathBoundCookie() -> String {
        if let scoped = parsedCookies.first(where: { !$0.path.isEmpty && $0.path != "/" }) {
            return scoped.pair
        }
        if let nonAcw = parsedCookies.first(where: { !$0.name.lowercased().hasPrefix("acw_") }) {
            return nonAcw.pair
        }
        return parsedCookies.first?.pair ?? ""
    }
}

public enum HTTPClientError: LocalizedError, Sendable {
    case invalidURL(String)
    case nonHTTPResponse
    case emptyBody(Int)
    case httpError(Int, String)
    case invalidJSON(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的链接地址：\(url)"
        case .nonHTTPResponse: return "服务端返回了无效响应"
        case .emptyBody(let code): return "服务端响应为空（HTTP \(code)）"
        case .httpError(let code, let msg): return msg.isEmpty ? "网络请求失败（HTTP \(code)）" : msg
        case .invalidJSON(let code): return "解析响应数据失败（HTTP \(code)）"
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class HTTPClient: Sendable {
    public static let shared = HTTPClient()

    /// 业务 API 会话（自动跟随跳转）
    public let apiSession: URLSession
    /// 禁止自动跳转会话（用于蓝奏云 / 重定向链精准控制）
    public let noRedirectSession: URLSession
    /// 高并发分片下载专用会话（扩大单主机最大并发数，避免 URLSession 默认 6 连接锁死并发）
    public let downloadSession: URLSession

    private let noRedirectDelegate = NoRedirectDelegate()

    public init() {
        let apiConfig = URLSessionConfiguration.ephemeral
        apiConfig.httpShouldSetCookies = false
        apiConfig.httpCookieAcceptPolicy = .never
        apiConfig.httpCookieStorage = nil
        apiConfig.urlCache = nil
        apiConfig.timeoutIntervalForRequest = 20
        apiConfig.timeoutIntervalForResource = 60
        apiConfig.httpMaximumConnectionsPerHost = 16
        self.apiSession = URLSession(configuration: apiConfig)

        let noRedirConfig = URLSessionConfiguration.ephemeral
        noRedirConfig.httpShouldSetCookies = false
        noRedirConfig.httpCookieAcceptPolicy = .never
        noRedirConfig.httpCookieStorage = nil
        noRedirConfig.urlCache = nil
        noRedirConfig.timeoutIntervalForRequest = 20
        noRedirConfig.timeoutIntervalForResource = 60
        self.noRedirectSession = URLSession(configuration: noRedirConfig, delegate: noRedirectDelegate, delegateQueue: nil)

        let dlConfig = URLSessionConfiguration.ephemeral
        dlConfig.httpShouldSetCookies = false
        dlConfig.httpCookieAcceptPolicy = .never
        dlConfig.httpCookieStorage = nil
        dlConfig.urlCache = nil
        dlConfig.timeoutIntervalForRequest = 30
        dlConfig.timeoutIntervalForResource = 60 * 60 * 4
        // 放开每主机并发连接数，支撑最高 64 路 Range 分片并发
        dlConfig.httpMaximumConnectionsPerHost = 64
        dlConfig.waitsForConnectivity = false
        self.downloadSession = URLSession(configuration: dlConfig)
    }

    public func send(
        url urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true
    ) async throws -> HTTPResponseData {
        guard let url = URL(string: urlString) else {
            throw HTTPClientError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.httpBody = body
        for (k, v) in headers where !v.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let session = followRedirects ? apiSession : noRedirectSession
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse
        }

        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headerMap[k] = v
            }
        }
        let parsedCookies = Self.extractParsedCookies(from: http)
        let setCookies = parsedCookies.isEmpty
            ? Self.extractSetCookies(from: http)
            : parsedCookies.map(\.pair)
        return HTTPResponseData(
            statusCode: http.statusCode,
            headers: headerMap,
            setCookies: setCookies,
            parsedCookies: parsedCookies,
            body: data,
            finalURL: http.url
        )
    }

    /// 提取结构化 Cookie（保留 Path，供 115 等需要识别路径绑定 CDN Cookie 的平台使用）
    public static func extractParsedCookies(from response: HTTPURLResponse) -> [ParsedHTTPCookie] {
        guard let url = response.url else { return [] }
        var stringFields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                stringFields[ks] = vs
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: stringFields, for: url)
        return parsed.map { ParsedHTTPCookie(name: $0.name, value: $0.value, path: $0.path) }
    }

    /// 精确提取所有 Set-Cookie（含单头合并逗号场景，通过 HTTPCookie.cookies(withResponseHeaderFields:for:) 还原）
    public static func extractSetCookies(from response: HTTPURLResponse) -> [String] {
        guard let url = response.url else { return [] }
        var stringFields: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                stringFields[ks] = vs
            }
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: stringFields, for: url)
        if !parsed.isEmpty {
            return parsed.map { "\($0.name)=\($0.value)" }
        }
        // 兜底：若系统未解析出，直接取原始 Set-Cookie 头
        for (k, v) in stringFields where k.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            return [v]
        }
        return []
    }
}
