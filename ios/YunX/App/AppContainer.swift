//
//  AppContainer.swift
//  YunX
//
//  应用级依赖装配容器（无第三方 DI 框架，清晰显式装配各层模块）。
//

import Foundation
import Observation

@MainActor
@Observable
public final class ToastManager {
    public private(set) var message: String?
    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ text: String, durationSeconds: Double = 2.6) {
        dismissTask?.cancel()
        message = text
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

@MainActor
@Observable
public final class AppContainer {
    public let settings: SettingsStore
    public let accountStore: AccountStore
    public let bookmarkStore: BookmarkStore
    public let backupService: AuthBackupService
    public let downloadManager: DownloadManager
    public let toast: ToastManager

    public let quarkProvider: QuarkProvider
    public let ucProvider: UCProvider
    public let pan123Provider: Pan123Provider
    public let lanzouProvider: LanzouProvider
    public let pan115Provider: Pan115Provider
    public let c139Provider: C139Provider
    public let xunleiProvider: XunleiProvider
    public let guangyaProvider: GuangYaProvider
    public let baiduProvider: BaiduProvider
    public let githubProvider: GitHubProvider

    /// 跨 Tab 跳转控制（入队下载后自动切至「下载」Tab）
    public var selectedTab: MainTab = .resolve

    public init() {
        let settings = SettingsStore()
        let accountStore = AccountStore()
        let bookmarkStore = BookmarkStore()
        let backupService = AuthBackupService(accountStore: accountStore)
        let downloadManager = DownloadManager(settings: settings)
        let toast = ToastManager()

        let quark = QuarkProvider()
        let uc = UCProvider()
        let pan123 = Pan123Provider()
        let lanzou = LanzouProvider()
        let pan115 = Pan115Provider()
        let c139 = C139Provider()
        let xunlei = XunleiProvider()
        let guangya = GuangYaProvider()
        let baidu = BaiduProvider()
        let github = GitHubProvider()

        // 绑定夸克/UC/迅雷 凭证自动回写续期（按原凭证匹配写回，避免多账号串号）
        quark.onCookieRefreshed = { [weak accountStore] merged, requestCookie in
            Task { @MainActor in
                accountStore?.updateCredentialIfMatching(platform: .quark, merged: merged, matching: requestCookie)
            }
        }
        uc.onCookieRefreshed = { [weak accountStore] merged, requestCookie in
            Task { @MainActor in
                accountStore?.updateCredentialIfMatching(platform: .uc, merged: merged, matching: requestCookie)
            }
        }
        xunlei.onCredentialRefreshed = { [weak accountStore] updated, oldRaw in
            Task { @MainActor in
                accountStore?.updateCredentialIfMatching(platform: .xunlei, merged: updated, matching: oldRaw)
            }
        }

        self.settings = settings
        self.accountStore = accountStore
        self.bookmarkStore = bookmarkStore
        self.backupService = backupService
        self.downloadManager = downloadManager
        self.toast = toast
        self.quarkProvider = quark
        self.ucProvider = uc
        self.pan123Provider = pan123
        self.lanzouProvider = lanzou
        self.pan115Provider = pan115
        self.c139Provider = c139
        self.xunleiProvider = xunlei
        self.guangyaProvider = guangya
        self.baiduProvider = baidu
        self.githubProvider = github
    }

    public func provider(for platform: SharePlatform) -> ShareResolveProvider? {
        switch platform {
        case .quark: return quarkProvider
        case .uc: return ucProvider
        case .pan123: return pan123Provider
        case .lanzou: return lanzouProvider
        case .pan115: return pan115Provider
        case .c139: return c139Provider
        case .xunlei: return xunleiProvider
        case .guangya: return guangyaProvider
        case .baidu: return baiduProvider
        case .github: return githubProvider
        case .ilanzou: return nil
        }
    }

    /// 获取个人网盘管理与分享转存提供者（覆盖 8 大网盘）
    public func cloudProvider(for platform: SharePlatform) -> CloudDriveProvider? {
        switch platform {
        case .quark: return quarkProvider
        case .uc: return ucProvider
        case .pan123: return pan123Provider
        case .pan115: return pan115Provider
        case .c139: return c139Provider
        case .xunlei: return xunleiProvider
        case .guangya: return guangyaProvider
        case .baidu: return baiduProvider
        case .lanzou, .github, .ilanzou: return nil
        }
    }
}
