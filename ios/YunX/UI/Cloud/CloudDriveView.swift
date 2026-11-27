//
//  CloudDriveView.swift
//  YunX
//
//  个人云盘 Tab 主界面：已登录网盘切换、空间配额条、面包屑导航、新建文件夹、重命名、删除与多线程高速下载。
//

import SwiftUI

struct CloudDriveView: View {
    let container: AppContainer
    @Bindable var viewModel: CloudDriveViewModel

    @State private var showCreateFolderAlert = false
    @State private var newFolderName = ""

    @State private var renameTarget: ShareFile?
    @State private var renameInput = ""

    @State private var deleteTarget: ShareFile?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.loggedInCloudPlatforms.isEmpty {
                    emptyLoginView
                } else {
                    cloudContentView
                }
            }
            .navigationTitle("个人云盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.selectedPlatform != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            newFolderName = ""
                            showCreateFolderAlert = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        Button {
                            Task { await viewModel.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
            }
            .alert("新建文件夹", isPresented: $showCreateFolderAlert) {
                TextField("请输入文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = newFolderName
                    Task { await viewModel.createFolder(name: name) }
                }
            }
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("输入新名称", text: $renameInput)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("确定") {
                    if let target = renameTarget {
                        let updated = renameInput
                        renameTarget = nil
                        Task { await viewModel.rename(file: target, newName: updated) }
                    }
                }
            }
            .confirmationDialog(
                "确认删除「\(deleteTarget?.fname ?? "")」？",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("移入回收站 / 删除", role: .destructive) {
                    if let target = deleteTarget {
                        deleteTarget = nil
                        Task { await viewModel.delete(file: target) }
                    }
                }
                Button("取消", role: .cancel) { deleteTarget = nil }
            }
            .overlay {
                if viewModel.isActing {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text(viewModel.actionMessage ?? "处理中…")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .task {
                await viewModel.syncPlatformSelectionIfNeeded()
            }
            .onChange(of: container.accountStore.accounts.count) { _, _ in
                Task { await viewModel.syncPlatformSelectionIfNeeded() }
            }
        }
    }

    // MARK: - 未登录引导态

    private var emptyLoginView: some View {
        ContentUnavailableView {
            Label("暂未登录个人网盘", systemImage: "externaldrive.badge.icloud")
        } description: {
            Text("登录后可直接浏览并管理夸克、UC、123、115、139、迅雷、光鸭、百度个人空间，并支持高速直链下载与分享一键转存。")
        } actions: {
            Button("前往登录账号") {
                container.selectedTab = .account
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 已登录网盘浏览器

    private var cloudContentView: some View {
        VStack(spacing: 0) {
            // 顶部已登录网盘切换栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.loggedInCloudPlatforms) { platform in
                        let selected = viewModel.selectedPlatform == platform
                        Button {
                            Task { await viewModel.selectPlatform(platform) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: platform.symbolName)
                                    .font(.caption)
                                Text(platform.displayName)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                selected ? Color(hex: platform.brandHex).opacity(0.18) : Color(.secondarySystemGroupedBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color(hex: platform.brandHex) : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color(.systemBackground))

            // 空间配额条
            if let quota = viewModel.quota {
                VStack(spacing: 5) {
                    HStack {
                        Text("已用空间")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Formatters.fileSize(quota.used)) / \(Formatters.fileSize(quota.total))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: quota.usageRatio)
                        .tint(Color(hex: viewModel.selectedPlatform?.brandHex ?? 0x4C8BF5))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(Color(.systemBackground))
            }

            // 目录面包屑
            if !viewModel.breadcrumbs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(viewModel.breadcrumbs.enumerated()), id: \.offset) { idx, node in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button(node.name) {
                                Task { await viewModel.navigateToBreadcrumb(index: idx) }
                            }
                            .font(.caption.weight(idx == viewModel.breadcrumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == viewModel.breadcrumbs.count - 1 ? .primary : .secondary)
                            .disabled(idx == viewModel.breadcrumbs.count - 1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
                .background(Color(.secondarySystemGroupedBackground))
            }

            Divider()

            // 主列表区
            if viewModel.isLoading {
                Spacer()
                ProgressView("正在加载个人网盘目录…")
                Spacer()
            } else if let err = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                } actions: {
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if viewModel.files.isEmpty {
                ContentUnavailableView("目录为空", systemImage: "folder", description: Text("点击右上角可新建文件夹，或从「解析」页转存文件到此目录"))
            } else {
                List(viewModel.files) { file in
                    fileRow(file)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = file
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                renameInput = file.fname
                                renameTarget = file
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
    }

    private func fileRow(_ file: ShareFile) -> some View {
        HStack(spacing: 12) {
            FileThumbnailView(file: file, enabled: container.settings.cloudThumbnailsEnabled)
            VStack(alignment: .leading, spacing: 3) {
                FileNameLabel(text: file.fname, multiLine: container.settings.fileNameMultiLine)
                Text(file.isdir ? "文件夹" : Formatters.fileSize(file.fsize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if !file.isdir {
                    Button {
                        Task { await viewModel.download(file: file) }
                    } label: {
                        Label("多线程高速下载", systemImage: "arrow.down.circle")
                    }
                }
                Button {
                    renameInput = file.fname
                    renameTarget = file
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    deleteTarget = file
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if file.isdir {
                Task { await viewModel.openFolder(file) }
            } else {
                Task { await viewModel.download(file: file) }
            }
        }
    }
}
