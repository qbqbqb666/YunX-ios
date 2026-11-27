//
//  AccountListView.swift
//  YunX
//
//  账号管理 Tab：展示首批四大网盘登录态、WebView/账号密码登录入口、手动粘贴 Cookie 与加密备份导入入口。
//

import SwiftUI

struct AccountListView: View {
    let container: AppContainer

    @State private var webLoginPlatform: SharePlatform?
    @State private var showPan123Login = false
    @State private var showXunleiLogin = false
    @State private var showGuangYaLogin = false
    @State private var manualCookiePlatform: SharePlatform?
    @State private var showBackupSheet = false

    private let activePlatforms: [SharePlatform] = [
        .quark, .uc, .pan123, .pan115, .c139, .xunlei, .guangya, .baidu, .lanzou, .github
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(activePlatforms) { platform in
                        accountRow(for: platform)
                    }
                } header: {
                    Text("已支持平台账号（10 大平台）")
                } footer: {
                    Text("所有登录凭证仅保存在本机 iOS Keychain 中，直接与对应平台官方通信，不经过任何第三方服务器。")
                }

                Section("跨端备份迁移") {
                    Button {
                        showBackupSheet = true
                    } label: {
                        Label("导入 / 导出云析加密备份（.yunx）", systemImage: "lock.doc.fill")
                    }
                }
            }
            .navigationTitle("账号")
            .sheet(item: $webLoginPlatform) { platform in
                WebLoginView(container: container, platform: platform)
            }
            .sheet(isPresented: $showPan123Login) {
                Pan123LoginView(container: container)
            }
            .sheet(isPresented: $showXunleiLogin) {
                XunleiLoginView(container: container)
            }
            .sheet(isPresented: $showGuangYaLogin) {
                GuangYaLoginView(container: container)
            }
            .sheet(item: $manualCookiePlatform) { platform in
                ManualCookieSheet(container: container, platform: platform)
            }
            .sheet(isPresented: $showBackupSheet) {
                BackupSheetView(container: container)
            }
        }
    }

    @ViewBuilder
    private func accountRow(for platform: SharePlatform) -> some View {
        let loggedIn = container.accountStore.isLoggedIn(platform)
        let record = container.accountStore.record(for: platform)

        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: platform.brandHex).opacity(loggedIn ? 0.18 : 0.08))
                    .frame(width: 42, height: 42)
                Image(systemName: platform.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: platform.brandHex).opacity(loggedIn ? 1.0 : 0.45))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(platform.displayName)
                        .font(.body.weight(.semibold))
                    if platform == .baidu {
                        Text("限速风控提示")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }
                if platform == .lanzou {
                    Text("分享解析无需登录，可直接高速下载")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if loggedIn {
                    Text(record?.nickname.isEmpty == false ? "已登录：\(record!.nickname)" : "已登录（凭证有效）")
                        .font(.caption)
                        .foregroundStyle(Color.yunxSuccess)
                } else if platform == .github {
                    Text("可选：配置 Token 提升 API 限额至 5000 次/小时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(platform.supportsGuestDownload ? "未登录（支持游客小文件/匿名解析）" : "未登录（取直链需要登录）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if platform != .lanzou {
                if loggedIn {
                    Menu {
                        Button("重新登录") { openLogin(for: platform) }
                        Button("手动更新凭证") { manualCookiePlatform = platform }
                        Divider()
                        Button("退出登录", role: .destructive) {
                            container.accountStore.removeAccount(for: platform)
                            container.toast.show("已退出\(platform.displayName)")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("登录") {
                        openLogin(for: platform)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if platform != .lanzou {
                Button {
                    manualCookiePlatform = platform
                } label: {
                    Label("手动粘贴 Cookie / Token", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    private func openLogin(for platform: SharePlatform) {
        switch platform {
        case .pan123:
            showPan123Login = true
        case .xunlei:
            showXunleiLogin = true
        case .guangya:
            showGuangYaLogin = true
        case .quark, .uc, .pan115, .c139, .baidu:
            webLoginPlatform = platform
        default:
            manualCookiePlatform = platform
        }
    }
}
