//
//  MainTabView.swift
//  YunX
//
//  主导航容器：解析 / 账号 / 下载 / 设置 四个原生 Tab + 全局 Toast 提示宿主。
//

import SwiftUI

public enum MainTab: Hashable {
    case resolve
    case cloud
    case download
    case account
    case settings
}

struct MainTabView: View {
    @Bindable var container: AppContainer
    @State private var resolveVM: ResolveViewModel
    @State private var cloudVM: CloudDriveViewModel

    init(container: AppContainer) {
        self.container = container
        self._resolveVM = State(initialValue: ResolveViewModel(container: container))
        self._cloudVM = State(initialValue: CloudDriveViewModel(container: container))
    }

    private var activeDownloadCount: Int {
        container.downloadManager.tasks.filter { $0.status == .downloading || $0.status == .pending }.count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $container.selectedTab) {
                ResolveView(container: container, viewModel: resolveVM)
                    .tabItem {
                        Label("解析", systemImage: "link.circle.fill")
                    }
                    .tag(MainTab.resolve)

                CloudDriveView(container: container, viewModel: cloudVM)
                    .tabItem {
                        Label("云盘", systemImage: "externaldrive.fill")
                    }
                    .tag(MainTab.cloud)

                DownloadListView(container: container)
                    .tabItem {
                        Label("下载", systemImage: "arrow.down.circle.fill")
                    }
                    .badge(activeDownloadCount)
                    .tag(MainTab.download)

                AccountListView(container: container)
                    .tabItem {
                        Label("账号", systemImage: "person.crop.circle.fill")
                    }
                    .tag(MainTab.account)

                SettingsView(container: container)
                    .tabItem {
                        Label("设置", systemImage: "gearshape.fill")
                    }
                    .tag(MainTab.settings)
            }
            .tint(.yunxBrand)

            if let toastMessage = container.toast.message {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial.opacity(0.01))
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 68)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.28), value: container.toast.message)
                    .allowsHitTesting(false)
            }
        }
    }
}
