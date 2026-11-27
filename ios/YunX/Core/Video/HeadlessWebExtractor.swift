//
//  HeadlessWebExtractor.swift
//  YunX
//
//  离屏 WKWebView 渲染提取器（供抖音过 byted_acrawler JS 挑战并读取详情 JSON / SSR）。
//

import Foundation
import WebKit

@MainActor
public final class HeadlessWebExtractor: NSObject {
    public static func loadAndExtract(
        url urlString: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        documentStartScripts: [String] = [],
        timeoutSeconds: Double = 35
    ) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        for script in documentStartScripts {
            config.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.customUserAgent = userAgent
        defer {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        webView.load(request)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var ready = false
        while Date() < deadline {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let val = try? await webView.evaluateJavaScript(readyCheckJS) as? String, val == "true" {
                ready = true
                break
            }
        }
        guard ready else { return nil }

        // 稍微等 300ms 让页面挂载收尾
        try? await Task.sleep(nanoseconds: 300_000_000)
        let wrappedExtract = "JSON.stringify(\(extractJS))"
        if let result = try? await webView.evaluateJavaScript(wrappedExtract) as? String, !result.isEmpty {
            return result
        }
        return nil
    }
}
