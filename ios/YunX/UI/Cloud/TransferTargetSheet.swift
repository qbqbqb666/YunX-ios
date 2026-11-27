//
//  TransferTargetSheet.swift
//  YunX
//
//  分享一键转存目标目录选择器：浏览个人网盘文件夹、原地新建子目录并执行转存。
//

import SwiftUI

struct TransferTargetSheet: View {
    let container: AppContainer
    let session: ShareSession
    let file: ShareFile
    let onTransferred: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var breadcrumbs: [BreadcrumbNode] = []
    @State private var folders: [ShareFile] = []
    @State private var isLoading = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    @State private var showCreateAlert = false
    @State private var newFolderName = ""

    private var currentDirFid: String {
        breadcrumbs.last?.id ?? session.platform.cloudRootDirFid
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 待转存条目摘要
                HStack(spacing: 10) {
                    FileTypeIconView(fileName: file.fname, isDir: file.isdir)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.fname)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("将转存至 \(session.platform.displayName) · \(breadcrumbs.last?.name ?? "根目录")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))

                // 面包屑
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { idx, node in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button(node.name) {
                                Task { await navigateBreadcrumb(index: idx) }
                            }
                            .font(.caption.weight(idx == breadcrumbs.count - 1 ? .semibold : .regular))
                            .foregroundStyle(idx == breadcrumbs.count - 1 ? .primary : .secondary)
                            .disabled(idx == breadcrumbs.count - 1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }

                Divider()

                // 目录列表（仅展示文件夹）
                if isLoading {
                    Spacer()
                    ProgressView("正在读取个人盘目录…")
                    Spacer()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("读取失败", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { Task { await loadFolders() } }
                            .buttonStyle(.bordered)
                    }
                } else if folders.isEmpty {
                    ContentUnavailableView("当前目录无子文件夹", systemImage: "folder", description: Text("可直接点击下方按钮转存到此目录"))
                } else {
                    List(folders) { folder in
                        HStack(spacing: 12) {
                            FileTypeIconView(fileName: folder.fname, isDir: true)
                            Text(folder.fname)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            breadcrumbs.append(BreadcrumbNode(id: folder.fid, name: folder.fname))
                            Task { await loadFolders() }
                        }
                    }
                    .listStyle(.plain)
                }

                Divider()

                // 底部操作栏
                HStack(spacing: 12) {
                    Button {
                        newFolderName = ""
                        showCreateAlert = true
                    } label: {
                        Label("新建目录", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)

                    Button {
                        Task { await confirmTransfer() }
                    } label: {
                        HStack {
                            if isSubmitting { ProgressView().tint(.white) }
                            Text(isSubmitting ? "正在转存…" : "转存到此目录")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting || isLoading)
                }
                .padding(14)
                .background(Color(.systemBackground))
            }
            .navigationTitle("选择转存目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("新建文件夹", isPresented: $showCreateAlert) {
                TextField("文件夹名称", text: $newFolderName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = newFolderName
                    Task { await createFolder(name: name) }
                }
            }
            .task {
                if breadcrumbs.isEmpty {
                    breadcrumbs = [BreadcrumbNode(id: session.platform.cloudRootDirFid, name: "根目录")]
                }
                await loadFolders()
            }
        }
    }

    private func navigateBreadcrumb(index: Int) async {
        guard index >= 0, index < breadcrumbs.count - 1 else { return }
        breadcrumbs = Array(breadcrumbs.prefix(index + 1))
        await loadFolders()
    }

    private func loadFolders() async {
        guard let cloud = container.cloudProvider(for: session.platform),
              let credential = container.accountStore.credential(for: session.platform) else {
            errorMessage = "请先在「账号」页登录\(session.platform.displayName)"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let items = try await cloud.listCloudFiles(dirFid: currentDirFid, credential: credential)
            folders = items
                .filter(\.isdir)
                .sorted { $0.fname.localizedStandardCompare($1.fname) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let cloud = container.cloudProvider(for: session.platform),
              let credential = container.accountStore.credential(for: session.platform) else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await cloud.createCloudFolder(parentFid: currentDirFid, name: trimmed, credential: credential)
            await loadFolders()
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }

    private func confirmTransfer() async {
        guard let cloud = container.cloudProvider(for: session.platform),
              let credential = container.accountStore.credential(for: session.platform) else {
            container.toast.show("请先在「账号」页登录\(session.platform.displayName)")
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await cloud.transferShareItem(
                session: session,
                file: file,
                toDirFid: currentDirFid,
                credential: credential
            )
            container.toast.show("已转存「\(file.fname)」到\(session.platform.displayName)")
            onTransferred()
            dismiss()
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }
}
