//
//  SettingsView.swift
//  YunX
//
//  设置 Tab：下载性能参数、iOS 前台防息屏、夸克免转存、外观主题、存储清理、加密备份与关于页。
//

import SwiftUI

struct SettingsView: View {
    @Bindable var container: AppContainer
    @State private var showBackupSheet = false
    @State private var diskUsageBytes: Int64 = 0

    private let threadOptions = [4, 8, 16, 24, 32, 48, 64]
    private let concurrentOptions = [1, 2, 3, 5, 8]
    private let speedLimitOptions: [(label: String, bps: Int64)] = [
        ("不限速", 0),
        ("2 MB/s", 2 * 1024 * 1024),
        ("5 MB/s", 5 * 1024 * 1024),
        ("10 MB/s", 10 * 1024 * 1024),
        ("20 MB/s", 20 * 1024 * 1024)
    ]

    var body: some View {
        @Bindable var settings = container.settings
        NavigationStack {
            Form {
                Section("多线程下载引擎") {
                    Picker("单任务分片线程数", selection: $settings.defaultDownloadThreads) {
                        ForEach(threadOptions, id: \.self) { count in
                            Text("\(count) 线程").tag(count)
                        }
                    }

                    Picker("最大同时下载任务数", selection: $settings.maxConcurrentDownloads) {
                        ForEach(concurrentOptions, id: \.self) { count in
                            Text("\(count) 个").tag(count)
                        }
                    }

                    Picker("全局速度限制", selection: $settings.speedLimitBytesPerSec) {
                        ForEach(speedLimitOptions, id: \.bps) { item in
                            Text(item.label).tag(item.bps)
                        }
                    }

                    Toggle("夸克优先免转存直链", isOn: $settings.quarkNoSaveDownload)
                    Toggle("下载时保持屏幕常亮", isOn: $settings.keepScreenAwakeWhileDownloading)
                }

                Section("通用与外观") {
                    Picker("外观主题", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Toggle("自动检测剪贴板链接", isOn: $settings.clipboardDetectEnabled)
                    Toggle("文件名多行完整显示", isOn: $settings.fileNameMultiLine)
                }

                Section("数据与存储") {
                    Button {
                        showBackupSheet = true
                    } label: {
                        Label("账号加密备份 / 恢复（兼容安卓）", systemImage: "key.fill")
                    }

                    HStack {
                        Label("已占本地空间", systemImage: "internaldrive")
                        Spacer()
                        Text(Formatters.fileSize(diskUsageBytes))
                            .foregroundStyle(.secondary)
                    }

                    Button("清理无效分片缓存") {
                        container.downloadManager.clearTempCache()
                        refreshDiskUsage()
                        container.toast.show("已清理闲置分片缓存")
                    }
                }

                Section("关于") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于云析 · YunX iOS", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear { refreshDiskUsage() }
            .sheet(isPresented: $showBackupSheet) {
                BackupSheetView(container: container)
            }
        }
    }

    private func refreshDiskUsage() {
        diskUsageBytes = container.downloadManager.totalDownloadsDiskUsage()
    }
}
