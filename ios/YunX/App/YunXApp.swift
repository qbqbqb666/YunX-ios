//
//  YunXApp.swift
//  YunX
//
//  云析 iOS 应用入口：绑定深浅色外观与前后台生命周期（切后台优雅暂停分片保断点）。
//

import SwiftUI

@main
struct YunXApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView(container: container)
                .preferredColorScheme(container.settings.appearance.colorScheme)
                .onOpenURL { url in
                    container.handleIncomingURL(url)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        // iOS 后台约 30s 会强制挂起普通网络流；主动安全暂停以保留分片完整度，切回秒续传
                        container.downloadManager.pauseAllForBackground()
                    }
                }
        }
    }
}
