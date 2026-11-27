//
//  ManualCookieSheet.swift
//  YunX
//
//  通用手动粘贴 Cookie / Token 兜底界面（WebView 遇风控时最可靠的备用入口）。
//

import SwiftUI

struct ManualCookieSheet: View {
    let container: AppContainer
    let platform: SharePlatform
    var asNewAccount: Bool = false
    var onSaved: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var rawCredential = ""
    @State private var isChecking = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(placeholderText, text: $rawCredential, axis: .vertical)
                        .lineLimit(4...8)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(headerTitle)
                } footer: {
                    Text(helperHint)
                }

                if let errorMsg {
                    Section {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await saveCredential() }
                    } label: {
                        HStack {
                            Spacer()
                            if isChecking { ProgressView() }
                            else { Text("验证并保存").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(rawCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
                }
            }
            .navigationTitle("手动配置\(platform.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var headerTitle: String {
        switch platform {
        case .pan123: return "Bearer JWT (authorToken)"
        case .xunlei, .guangya: return "Access Token（或 JSON 凭证）"
        case .github: return "GitHub Personal Access Token"
        default: return "完整 Cookie 字符串"
        }
    }

    private var placeholderText: String {
        switch platform {
        case .pan123: return "粘贴 eyJhbGci... 格式的 authorToken"
        case .pan115: return "粘贴包含 UID=...; CID=...; SEID=... 的完整 Cookie"
        case .c139: return "粘贴含 authorization=Basic ... 或 Os_SSo_Sid / RMKEY 的 Cookie"
        case .xunlei, .guangya: return "粘贴 Access Token（不带 Bearer 前缀亦可）"
        case .baidu: return "粘贴包含 BDUSS=...; STOKEN=... 的完整 Cookie"
        case .github: return "粘贴 ghp_... 或 github_pat_... 格式的 Token"
        default: return "粘贴包含 __pus=...; __puus=... 的完整 Cookie"
        }
    }

    private var helperHint: String {
        switch platform {
        case .quark, .uc:
            return "在桌面浏览器登录官网后，从开发者工具 Network 请求头中复制完整 Cookie 粘贴于此。"
        case .pan123:
            return "在桌面浏览器登录 yun.123pan.cn 后，从 Application -> Local Storage 中复制 authorToken 的值。"
        case .pan115:
            return "在桌面浏览器登录 115.com 后，复制包含 UID、CID、SEID、KID 的完整 Cookie。"
        case .c139:
            return "在浏览器登录 yun.139.com 后，复制包含 authorization 或 Os_SSo_Sid + RMKEY 的 Cookie。"
        case .xunlei:
            return "推荐使用原生短信/密码登录；手动模式可粘贴 Bearer Access Token。"
        case .guangya:
            return "推荐使用原生密码/短信登录；手动模式可粘贴光鸭 Access Token。"
        case .baidu:
            return "在浏览器登录 pan.baidu.com 后复制含 BDUSS 的 Cookie（请知悉百度网盘高频下载存在限速或风控风险）。"
        case .github:
            return "可选配置：在 GitHub Settings -> Developer settings 生成只读 Personal Access Token，可将 API 限额从 60 次/小时提升至 5000 次/小时。"
        default:
            return "凭证仅保存在本机 iOS Keychain 中。"
        }
    }

    private func saveCredential() async {
        let cleaned = rawCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        isChecking = true
        errorMsg = nil
        defer { isChecking = false }

        let nick = await container.provider(for: platform)?.fetchNickname(credential: cleaned)
        container.accountStore.saveAccount(platform: platform, credential: cleaned, nickname: nick ?? "", asNewAccount: asNewAccount)
        container.toast.show(nick != nil ? "已验证并保存：\(nick!)" : "已保存\(platform.displayName)凭证")
        dismiss()
        onSaved?()
    }
}
