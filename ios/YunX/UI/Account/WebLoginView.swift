//
//  WebLoginView.swift
//  YunX
//
//  基于 WKWebView + WKHTTPCookieStore 的官方网页登录器（支持读取 HttpOnly Cookie 如 __puus / __pus）。
//  提供自动检测登录完成保存 + 右上角手动保存与手动粘贴 Cookie 兜底。
//

import SwiftUI
import WebKit

struct WebLoginView: View {
    let container: AppContainer
    let platform: SharePlatform
    var asNewAccount: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var webViewRef: WKWebView?
    @State private var isLoading = true
    @State private var isVerifying = false
    @State private var showManualSheet = false
    @State private var statusHint = "请在下方官方网页完成登录，登录成功后将自动提取凭证"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if isLoading || isVerifying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(Color.yunxBrand)
                    }
                    Text(statusHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground))

                LoginWebViewRepresentable(
                    urlString: loginURL,
                    customUserAgent: customUA,
                    isLoading: $isLoading,
                    webViewRef: $webViewRef,
                    onPageDidFinish: {
                        Task { await checkAndSaveCredential(silent: true) }
                    }
                )
            }
            .navigationTitle("登录\(platform.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showManualSheet = true
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    Button("保存") {
                        Task { await checkAndSaveCredential(silent: false) }
                    }
                    .fontWeight(.semibold)
                    .disabled(isVerifying)
                }
            }
            .sheet(isPresented: $showManualSheet) {
                ManualCookieSheet(container: container, platform: platform) {
                    dismiss()
                }
            }
            .task {
                // 周期自动探测登录完成（每 2.5 秒读取一次 WKHTTPCookieStore，支持扫码/短信登录无跳转场景）
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if !isVerifying && !showManualSheet {
                        await checkAndSaveCredential(silent: true)
                    }
                }
            }
        }
    }

    private var loginURL: String {
        switch platform {
        case .quark: return QuarkConstants.loginURL
        case .uc: return UCConstants.loginURL
        case .pan123: return Pan123Constants.webLoginURL
        case .pan115: return Pan115Constants.webLoginURL
        case .c139: return C139Constants.loginURL
        case .baidu: return BaiduConstants.loginURL
        default: return "https://pan.quark.cn/"
        }
    }

    private var customUA: String {
        switch platform {
        case .quark: return QuarkConstants.webLoginUserAgent
        case .uc: return UCConstants.userAgent
        case .pan123: return Pan123Constants.webUA
        case .pan115: return Pan115Constants.webUA
        case .c139: return C139Constants.shareMobileUA
        case .baidu: return BaiduConstants.uaWeb
        default: return QuarkConstants.webLoginUserAgent
        }
    }

    private var targetDomains: [String] {
        switch platform {
        case .quark: return QuarkConstants.cookieDomains
        case .uc: return UCConstants.cookieDomains
        case .pan115: return Pan115Constants.cookieDomains
        case .c139: return C139Constants.cookieDomains
        case .baidu: return BaiduConstants.cookieDomains
        default: return []
        }
    }

    private func checkAndSaveCredential(silent: Bool) async {
        guard let webView = webViewRef, !isVerifying else { return }

        if platform == .pan123 {
            // 123 网页版登录态在 localStorage.authorToken
            guard let token = (try? await webView.evaluateJavaScript("localStorage.getItem('authorToken')")) as? String,
                  Pan123Signer.isValidToken(token) else {
                if !silent { container.toast.show("尚未检测到 123 登录凭证，请先完成登录") }
                return
            }
            isVerifying = true
            statusHint = "正在校验 123 登录态…"
            defer { isVerifying = false }
            let nick = await container.pan123Provider.fetchNickname(credential: token)
            if let nick {
                container.accountStore.saveAccount(platform: .pan123, credential: token, nickname: nick, asNewAccount: asNewAccount)
                container.toast.show("123 云盘登录成功：\(nick)")
                dismiss()
            } else if !silent {
                statusHint = "凭证校验未通过，请刷新重试"
            }
            return
        }

        // 夸克 / UC：使用 WKHTTPCookieStore 完整提取 HttpOnly Cookie
        let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let filtered = allCookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return targetDomains.contains { target in
                domain == target || domain.hasSuffix(".\(target)") || target.hasSuffix(domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            }
        }
        var dedup: [String: String] = [:]
        for c in filtered {
            dedup[c.name] = c.value
        }
        let cookieStr = dedup.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")

        let plausible: Bool
        switch platform {
        case .quark: plausible = QuarkConstants.isValidCookie(cookieStr)
        case .uc: plausible = UCConstants.isValidCookie(cookieStr)
        case .pan115: plausible = Pan115Constants.isValidCookie(cookieStr)
        case .c139: plausible = C139Constants.isValidCookie(cookieStr)
        case .baidu: plausible = BaiduConstants.isValidCookie(cookieStr)
        default: plausible = !cookieStr.isEmpty
        }

        guard plausible else {
            if !silent { container.toast.show("未检测到完整登录 Cookie，请先完成网页登录") }
            return
        }

        isVerifying = true
        statusHint = "检测到登录态，正在校验账号信息…"
        defer { isVerifying = false }

        if let provider = container.provider(for: platform),
           let nickname = await provider.fetchNickname(credential: cookieStr) {
            container.accountStore.saveAccount(platform: platform, credential: cookieStr, nickname: nickname, asNewAccount: asNewAccount)
            container.toast.show("\(platform.displayName)登录成功：\(nickname)")
            dismiss()
        } else {
            statusHint = "已获取 Cookie，等待官方接口确认…"
            if !silent {
                // 用户手动点击保存时兜底落库，避免因接口波动无法保存
                container.accountStore.saveAccount(platform: platform, credential: cookieStr, asNewAccount: asNewAccount)
                container.toast.show("已保存\(platform.displayName) Cookie")
                dismiss()
            }
        }
    }
}

private struct LoginWebViewRepresentable: UIViewRepresentable {
    let urlString: String
    let customUserAgent: String
    @Binding var isLoading: Bool
    @Binding var webViewRef: WKWebView?
    let onPageDidFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onPageDidFinish: onPageDidFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 使用独立非持久会话，确保干净的登录环境，不与历史失效 Cookie 冲突
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = customUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        DispatchQueue.main.async {
            self.webViewRef = webView
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        let onPageDidFinish: () -> Void

        init(isLoading: Binding<Bool>, onPageDidFinish: @escaping () -> Void) {
            self._isLoading = isLoading
            self.onPageDidFinish = onPageDidFinish
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            onPageDidFinish()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}
