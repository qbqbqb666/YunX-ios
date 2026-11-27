//
//  DeepLinkHandler.swift
//  YunX
//
//  外部唤起深度链接解析与自动分流：
//  支持 yunx://resolve?text=... / yunx://resolve?url=...，自动识别网盘分享或视频链接。
//

import Foundation

public enum DeepLinkTargetMode: String, Sendable, Equatable {
    case cloud
    case video
}

public struct DeepLinkRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let mode: DeepLinkTargetMode
    public let rawText: String

    public init(id: UUID = UUID(), mode: DeepLinkTargetMode, rawText: String) {
        self.id = id
        self.mode = mode
        self.rawText = rawText
    }
}

public enum DeepLinkHandler {
    public static let urlScheme = "yunx"

    /// 构造由 Share Extension 或快捷指令唤起主 App 的 URL
    public static func makeResolveURL(text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "resolve"
        components.queryItems = [URLQueryItem(name: "text", value: trimmed)]
        return components.url
    }

    /// 解析传入的 `yunx://` URL，并按链接特征自动判定路由到网盘解析或视频解析
    public static func parse(url: URL) -> DeepLinkRequest? {
        guard url.scheme?.lowercased() == urlScheme else { return nil }
        let host = (url.host ?? "").lowercased()
        guard host.isEmpty || host == "resolve" || host == "open" || host == "share" else {
            return nil
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let textParam = items.first(where: { $0.name == "text" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlParam = items.first(where: { $0.name == "url" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = (textParam?.isEmpty == false ? textParam : nil) ?? (urlParam?.isEmpty == false ? urlParam : nil)
        guard let payload, !payload.isEmpty else { return nil }

        let mode: DeepLinkTargetMode
        if ShareLinkParser.parse(payload) != nil {
            mode = .cloud
        } else if VideoLinkParser.looksLikeVideoLink(payload) {
            mode = .video
        } else {
            mode = .cloud
        }
        return DeepLinkRequest(mode: mode, rawText: payload)
    }
}
