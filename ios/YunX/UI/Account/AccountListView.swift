//
//  AccountListView.swift
//  YunX
//
//  账号管理 Tab：覆盖全部 11 大网盘登录态、同平台多账号管理与一键切号、手动粘贴凭证与加密备份导入导出。
//

import SwiftUI

private struct AccountLoginTarget: Identifiable {
    let id = UUID()
    let platform: SharePlatform
    let asNewAccount: Bool
}

struct AccountListView: View {
    let container: AppContainer

    @State private var webLoginTarget: AccountLoginTarget?
    @State private var pan123AsNew: Bool = false
    @State private var showPan123Login = false
    @State private var xunleiAsNew: Bool = false
    @State private var showXunleiLogin = false
    @State private var guangyaAsNew: Bool = false
    @State private var showGuangYaLogin = false
    @State private var ilanzouAsNew: Bool = false
    @State private var showILanzouLogin = false
    @State private var manualCookieTarget: AccountLoginTarget?
    @State private var manageMultiAccountPlatform: SharePlatform?
    @State private var videoLoginPlatform: VideoPlatform?
    @State private var showBackupSheet = false

    private let activePlatforms: [SharePlatform] = [
        .quark, .uc, .pan123, .pan115, .c139, .xunlei, .guangya, .baidu, .ilanzou, .lanzou, .github
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(activePlatforms) { platform in
                        accountRow(for: platform)
                    }
                } header: {
                    Text("全平台账号管理（11 大平台 · 支持多账号切换）")
                } footer: {
                    Text("所有登录凭证仅保存在本机 iOS Keychain 中，直接与对应平台官方通信，不经过任何第三方服务器。同平台可添加多个账号并随时一键切换。")
                }

                Section("视频解析账号") {
                    ForEach(VideoPlatform.loginPlatforms) { vp in
                        videoAccountRow(for: vp)
                    }
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
            .sheet(item: $webLoginTarget) { target in
                WebLoginView(container: container, platform: target.platform, asNewAccount: target.asNewAccount)
            }
            .sheet(isPresented: $showPan123Login) {
                Pan123LoginView(container: container, asNewAccount: pan123AsNew)
            }
            .sheet(isPresented: $showXunleiLogin) {
                XunleiLoginView(container: container, asNewAccount: xunleiAsNew)
            }
            .sheet(isPresented: $showGuangYaLogin) {
                GuangYaLoginView(container: container, asNewAccount: guangyaAsNew)
            }
            .sheet(isPresented: $showILanzouLogin) {
                ILanzouLoginView(container: container, asNewAccount: ilanzouAsNew)
            }
            .sheet(item: $manualCookieTarget) { target in
                ManualCookieSheet(container: container, platform: target.platform, asNewAccount: target.asNewAccount)
            }
            .sheet(item: $manageMultiAccountPlatform) { platform in
                PlatformAccountsSheet(
                    container: container,
                    platform: platform,
                    onAddAccount: { openLogin(for: platform, asNewAccount: true) },
                    onManualAdd: { manualCookieTarget = AccountLoginTarget(platform: platform, asNewAccount: true) }
                )
            }
            .sheet(item: $videoLoginPlatform) { vp in
                VideoAccountLoginSheet(container: container, platform: vp)
            }
            .sheet(isPresented: $showBackupSheet) {
                BackupSheetView(container: container)
            }
        }
    }

    @ViewBuilder
    private func accountRow(for platform: SharePlatform) -> some View {
        let slotList = container.accountStore.accounts(for: platform)
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
                    if slotList.count > 1 {
                        Text("\(slotList.count) 账号")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.yunxBrand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yunxBrand.opacity(0.14), in: Capsule())
                    }
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
                    Text("当前：\(record?.displayTitle ?? "已登录（凭证有效）")")
                        .font(.caption)
                        .foregroundStyle(Color.yunxSuccess)
                } else if platform == .github {
                    Text("可选：配置 Token 提升 API 限额至 5000 次/小时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(platform.supportsGuestDownload ? "未登录（支持游客/匿名解析）" : "未登录（取直链需要登录）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if platform != .lanzou {
                if loggedIn {
                    Menu {
                        if slotList.count > 1 {
                            Section("快速切换当前账号") {
                                ForEach(slotList) { slot in
                                    Button {
                                        container.accountStore.setPrimary(accountId: slot.id, for: platform)
                                        container.toast.show("已切换\(platform.displayName)为「\(slot.displayTitle)」")
                                    } label: {
                                        if slot.isPrimary {
                                            Label(slot.displayTitle, systemImage: "checkmark")
                                        } else {
                                            Text(slot.displayTitle)
                                        }
                                    }
                                }
                            }
                        }
                        Button {
                            manageMultiAccountPlatform = platform
                        } label: {
                            Label("管理多账号（\(slotList.count)）", systemImage: "person.2")
                        }
                        Button {
                            openLogin(for: platform, asNewAccount: true)
                        } label: {
                            Label("添加新账号", systemImage: "person.badge.plus")
                        }
                        Divider()
                        Button("重新登录当前账号") { openLogin(for: platform, asNewAccount: false) }
                        Button("手动更新凭证") {
                            manualCookieTarget = AccountLoginTarget(platform: platform, asNewAccount: false)
                        }
                        Divider()
                        Button("退出当前账号", role: .destructive) {
                            container.accountStore.removeAccount(for: platform)
                            container.toast.show("已退出\(platform.displayName)当前账号")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("登录") {
                        openLogin(for: platform, asNewAccount: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if platform != .lanzou && loggedIn {
                manageMultiAccountPlatform = platform
            }
        }
        .contextMenu {
            if platform != .lanzou {
                if loggedIn {
                    Button {
                        manageMultiAccountPlatform = platform
                    } label: {
                        Label("管理多账号", systemImage: "person.2")
                    }
                }
                Button {
                    manualCookieTarget = AccountLoginTarget(platform: platform, asNewAccount: loggedIn)
                } label: {
                    Label(loggedIn ? "手动粘贴新增账号" : "手动粘贴 Cookie / Token", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    private func videoAccountRow(for vp: VideoPlatform) -> some View {
        let loggedIn = container.videoAccountStore.isLoggedIn(vp)
        let record = container.videoAccountStore.record(for: vp)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(hex: vp.brandHex).opacity(loggedIn ? 0.18 : 0.08))
                    .frame(width: 42, height: 42)
                Image(systemName: vp.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: vp.brandHex).opacity(loggedIn ? 1.0 : 0.45))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(vp.displayName)
                    .font(.body.weight(.semibold))
                if loggedIn {
                    Text(record?.nickname.isEmpty == false ? "已登录：\(record!.nickname)" : "已登录（Cookie 有效）")
                        .font(.caption)
                        .foregroundStyle(Color.yunxSuccess)
                } else {
                    Text(vp.loginBenefit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if loggedIn {
                Menu {
                    Button("更新 Cookie / 重登") { videoLoginPlatform = vp }
                    Divider()
                    Button("退出登录", role: .destructive) {
                        container.videoAccountStore.removeAccount(for: vp)
                        container.toast.show("已退出\(vp.displayName)")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(vp.manualCookieOnly ? "配置" : "登录") {
                    videoLoginPlatform = vp
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func openLogin(for platform: SharePlatform, asNewAccount: Bool) {
        switch platform {
        case .pan123:
            pan123AsNew = asNewAccount
            showPan123Login = true
        case .xunlei:
            xunleiAsNew = asNewAccount
            showXunleiLogin = true
        case .guangya:
            guangyaAsNew = asNewAccount
            showGuangYaLogin = true
        case .ilanzou:
            ilanzouAsNew = asNewAccount
            showILanzouLogin = true
        case .quark, .uc, .pan115, .c139, .baidu:
            webLoginTarget = AccountLoginTarget(platform: platform, asNewAccount: asNewAccount)
        default:
            manualCookieTarget = AccountLoginTarget(platform: platform, asNewAccount: asNewAccount)
        }
    }
}
