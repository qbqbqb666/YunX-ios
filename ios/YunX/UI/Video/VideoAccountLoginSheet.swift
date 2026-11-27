//
//  VideoAccountLoginSheet.swift
//  YunX
//
//  视频解析平台登录弹窗：哔哩哔哩/小红书支持内置桌面 UA WKWebView 网页登录 + 手动粘贴 Cookie；
//  Pixiv 按安卓端经验仅展示手动粘贴 Cookie（避免 WebView reCAPTCHA 必拒）。
//

import SwiftUI
import WebKit

struct VideoAccountLoginSheet: View {
    let container: AppContainer
    let platform: VideoPlatform

    @Environment(\.dismiss) private var dismiss
    @State private var useManualMode: Bool = false
    @State private var rawCookie: String = ""
    @State private var isChecking: Bool = false
    @State private var errorMsg: String?
    @State private var webViewRef: WKWebView?

    var body: some View {
        NavigationStack {
            Group {
                if platform.manualCookieOnly || useManualMode {
                    manualForm
                } else {
                    webLoginContent
                }
            }
            .navigationTitle("登录 \(platform.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if !platform.manualCookieOnly {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(useManualMode ? "网页登录" : "手动粘贴") {
                            useManualMode.toggle()
                        }
                    }
                }
            }
        }
    }

    private var webLoginContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(Color.yunxBrand)
                }
                Text(platform.loginBenefit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("完成并保存") {
                    Task { await extractCookiesFromWebView() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isChecking)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))

            if let errorMsg {
                Text(errorMsg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            VideoLoginWebViewRepresentable(
                urlString: platform.loginURL,
                userAgent: VideoHTTP.uaChrome,
                webViewBinding: $webViewRef
            )
        }
    }

    private var manualForm: some View {
        Form {
            Section {
                TextField("粘贴 \(platform.displayName) 完整 Cookie（例如 PHPSESSID=... / SESSDATA=...）", text: $rawCookie, axis: .vertical)
                    .lineLimit(4...8)
                    .font(.caption.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("\(platform.displayName) Cookie")
            } footer: {
                Text(platform.loginBenefit)
            }

            if let errorMsg {
                Section {
                    Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { await verifyAndSave(cookie: rawCookie) }
                } label: {
                    HStack {
                        Spacer()
                        if isChecking { ProgressView().padding(.trailing, 6) }
                        Text(isChecking ? "正在验证…" : "验证并保存 Cookie")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isChecking || rawCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func extractCookiesFromWebView() async {
        guard let webView = webViewRef else { return }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let filtered = cookies.filter { cookie in
            platform.cookieDomain.isEmpty || cookie.domain.lowercased().contains(platform.cookieDomain.lowercased())
        }
        let header = filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard !header.isEmpty else {
            errorMsg = "未检测到有效 Cookie，请确认已在页面中完成登录"
            return
        }
        await verifyAndSave(cookie: header)
    }

    private func verifyAndSave(cookie: String) async {
        let cleaned = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        isChecking = true
        errorMsg = nil
        defer { isChecking = false }

        let nick = await container.videoParseService.parser(for: platform)?.validateCookie(cleaned)
        if let nick {
            container.videoAccountStore.saveCookie(platform: platform, cookie: cleaned, nickname: nick)
            container.toast.show(nick.isEmpty ? "\(platform.displayName)已登录" : "\(platform.displayName)已登录：\(nick)")
            dismiss()
        } else {
            // 允许用户保存兜底（网络抖动或风控接口变动时不阻断手动粘贴）
            container.videoAccountStore.saveCookie(platform: platform, cookie: cleaned, nickname: "")
            container.toast.show("已保存 \(platform.displayName) Cookie")
            dismiss()
        }
    }
}

private struct VideoLoginWebViewRepresentable: UIViewRepresentable {
    let urlString: String
    let userAgent: String
    @Binding var webViewBinding: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = userAgent
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        DispatchQueue.main.async {
            webViewBinding = webView
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
