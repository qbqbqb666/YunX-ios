//
//  DownloadListView.swift
//  YunX
//
//  下载管理 Tab：
//  - 顶部总速度栏 + 手动添加 HTTP 直链入口；
//  - 进行中 / 已完成分区展示，支持实时分片合并进度、暂停/继续/重试/删除；
//  - 已完成文件支持原生 QuickLook 预览与系统 ShareLink 导出（同时直接可在系统「文件」App 访问）。
//

import SwiftUI

struct DownloadListView: View {
    let container: AppContainer
    @State private var showAddManualSheet = false
    @State private var previewURL: URL?

    private var activeTasks: [DownloadTask] {
        container.downloadManager.tasks.filter { $0.status != .completed }
    }

    private var completedTasks: [DownloadTask] {
        container.downloadManager.tasks.filter { $0.status == .completed }
    }

    var body: some View {
        NavigationStack {
            Group {
                if container.downloadManager.tasks.isEmpty {
                    ContentUnavailableView(
                        "暂无下载任务",
                        systemImage: "arrow.down.circle",
                        description: Text("在「解析」页粘贴网盘分享链接，或点右上角「+」添加 HTTP 直链开始多线程高速下载。")
                    )
                } else {
                    List {
                        if container.downloadManager.hasActiveDownloads {
                            Section {
                                HStack {
                                    Label("全局实时速度", systemImage: "speedometer")
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(Formatters.speed(container.downloadManager.totalSpeedBytesPerSec))
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(Color.yunxBrand)
                                }
                            }
                        }

                        if !activeTasks.isEmpty {
                            Section("进行中 (\(activeTasks.count))") {
                                ForEach(activeTasks) { task in
                                    downloadRow(task)
                                }
                            }
                        }

                        if !completedTasks.isEmpty {
                            Section {
                                ForEach(completedTasks) { task in
                                    downloadRow(task)
                                }
                            } header: {
                                HStack {
                                    Text("已完成 (\(completedTasks.count))")
                                    Spacer()
                                    Button("清除记录") {
                                        container.downloadManager.clearCompleted(deleteFiles: false)
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddManualSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddManualSheet) {
                ManualDownloadSheet(container: container)
            }
            .sheet(item: Binding(
                get: { previewURL.map { IdentifiableURL(url: $0) } },
                set: { if $0 == nil { previewURL = nil } }
            )) { wrapper in
                FilePreviewSheet(url: wrapper.url)
            }
        }
    }

    @ViewBuilder
    private func downloadRow(_ task: DownloadTask) -> some View {
        let liveStats = container.downloadManager.stats[task.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                FileTypeIconView(fileName: task.displayFileName, isDir: false)

                VStack(alignment: .leading, spacing: 3) {
                    FileNameLabel(text: task.displayFileName, multiLine: container.settings.fileNameMultiLine)
                    HStack(spacing: 6) {
                        Text(task.platform.displayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.yunxBrand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yunxBrand.opacity(0.12), in: Capsule())

                        if let folder = task.folderGroup {
                            Text(folder)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Text(statusSubtitle(task: task, stats: liveStats))
                            .font(.caption)
                            .foregroundStyle(task.status == .failed ? .red : .secondary)
                    }
                }

                Spacer()

                actionButtons(for: task)
            }

            if task.status != .completed {
                if let mergePct = liveStats?.mergePercent {
                    ProgressView(value: Double(mergePct), total: 100)
                        .tint(.orange)
                } else {
                    ProgressView(value: task.progress)
                        .tint(task.status == .failed ? .red : .yunxBrand)
                }

                HStack {
                    Text("\(Formatters.fileSize(task.downloadedSize)) / \(Formatters.fileSize(task.totalSize))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let mergePct = liveStats?.mergePercent {
                        Text("合并分片中 · \(mergePct)%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if task.status == .downloading, let liveStats {
                        Text("\(Formatters.speed(liveStats.speedBytesPerSec)) · 剩余 \(Formatters.remainingTime(liveStats.remainingSeconds))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.yunxBrand)
                    } else if let err = task.errorMessage, task.status == .failed {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                container.downloadManager.remove(taskId: task.id, deleteLocalFile: true)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for task: DownloadTask) -> some View {
        switch task.status {
        case .downloading, .pending:
            Button {
                container.downloadManager.pause(taskId: task.id)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)

        case .paused, .failed:
            Button {
                container.downloadManager.resume(taskId: task.id)
            } label: {
                Image(systemName: task.status == .failed ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.yunxBrand)
            }
            .buttonStyle(.plain)

        case .completed:
            if let fileURL = container.downloadManager.localFileURL(for: task) {
                HStack(spacing: 12) {
                    Button {
                        previewURL = fileURL
                    } label: {
                        Image(systemName: "eye.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.yunxBrand)
                    }
                    .buttonStyle(.plain)

                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.yunxSuccess)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func statusSubtitle(task: DownloadTask, stats: DownloadStats?) -> String {
        switch task.status {
        case .completed:
            let avg = task.averageSpeed > 0 ? " · 均速 \(Formatters.speed(task.averageSpeed))" : ""
            return "\(Formatters.fileSize(task.totalSize))\(avg)"
        case .downloading:
            if let workers = stats?.activeWorkers, workers > 0 {
                return "\(workers) 线程并发中"
            }
            return "连接中…"
        default:
            return task.status.label
        }
    }
}

private struct ManualDownloadSheet: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var fileName = ""
    @State private var referer = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("直链地址") {
                    TextField("https://...", text: $urlText, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("自定义文件名（留空自动识别）", text: $fileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Referer 请求头（可选）", text: $referer)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("开始多线程高速下载") {
                        var headers: [String: String] = ["User-Agent": QuarkConstants.apiUserAgent]
                        let trimmedRef = referer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedRef.isEmpty { headers["Referer"] = trimmedRef }
                        container.downloadManager.enqueue(
                            url: urlText.trimmingCharacters(in: .whitespacesAndNewlines),
                            fileName: fileName.trimmingCharacters(in: .whitespacesAndNewlines),
                            headers: headers,
                            platform: .generic
                        )
                        container.toast.show("已添加直链下载任务")
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!urlText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http"))
                }
            }
            .navigationTitle("手动添加直链")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

private struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}
