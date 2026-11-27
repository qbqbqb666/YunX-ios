//
//  CloudDriveViewModel.swift
//  YunX
//
//  个人云盘管理状态机：多网盘切换、容量配额查询、目录面包屑浏览、新建文件夹、重命名、删除与直链高速下载。
//

import Foundation
import Observation

@MainActor
@Observable
public final class CloudDriveViewModel {
    public var selectedPlatform: SharePlatform?
    public private(set) var quota: CloudQuota?
    public private(set) var breadcrumbs: [BreadcrumbNode] = []
    public private(set) var files: [ShareFile] = []
    public private(set) var isLoading: Bool = false
    public private(set) var isActing: Bool = false
    public private(set) var actionMessage: String?
    public private(set) var errorMessage: String?

    private let container: AppContainer

    public init(container: AppContainer) {
        self.container = container
    }

    public var loggedInCloudPlatforms: [SharePlatform] {
        SharePlatform.cloudDrivePlatforms.filter { container.accountStore.isLoggedIn($0) }
    }

    public var currentDirFid: String {
        breadcrumbs.last?.id ?? (selectedPlatform?.cloudRootDirFid ?? "")
    }

    /// 每次切入「云盘」Tab 时自动对齐当前已登录平台
    public func syncPlatformSelectionIfNeeded() async {
        let available = loggedInCloudPlatforms
        if let current = selectedPlatform, available.contains(current) {
            if files.isEmpty && !isLoading {
                await loadCurrentDirectory()
            }
            return
        }
        if let first = available.first {
            await selectPlatform(first)
        } else {
            selectedPlatform = nil
            quota = nil
            breadcrumbs = []
            files = []
            errorMessage = nil
        }
    }

    public func selectPlatform(_ platform: SharePlatform) async {
        selectedPlatform = platform
        quota = nil
        let rootId = platform.cloudRootDirFid
        breadcrumbs = [BreadcrumbNode(id: rootId, name: platform.displayName)]
        files = []
        errorMessage = nil

        async let quotaTask: Void = loadQuota(for: platform)
        async let listTask: Void = loadCurrentDirectory()
        _ = await (quotaTask, listTask)
    }

    public func refresh() async {
        guard let platform = selectedPlatform else { return }
        async let quotaTask: Void = loadQuota(for: platform)
        async let listTask: Void = loadCurrentDirectory()
        _ = await (quotaTask, listTask)
    }

    public func openFolder(_ folder: ShareFile) async {
        guard folder.isdir else { return }
        breadcrumbs.append(BreadcrumbNode(id: folder.fid, name: folder.fname))
        await loadCurrentDirectory()
    }

    public func navigateToBreadcrumb(index: Int) async {
        guard index >= 0, index < breadcrumbs.count - 1 else { return }
        breadcrumbs = Array(breadcrumbs.prefix(index + 1))
        await loadCurrentDirectory()
    }

    public func createFolder(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let platform = selectedPlatform,
              let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else { return }

        isActing = true
        actionMessage = "正在创建文件夹…"
        defer {
            isActing = false
            actionMessage = nil
        }
        do {
            _ = try await cloud.createCloudFolder(parentFid: currentDirFid, name: trimmed, credential: credential)
            container.toast.show("已创建文件夹「\(trimmed)」")
            await loadCurrentDirectory()
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }

    public func rename(file: ShareFile, newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.fname,
              let platform = selectedPlatform,
              let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else { return }

        isActing = true
        actionMessage = "正在重命名…"
        defer {
            isActing = false
            actionMessage = nil
        }
        do {
            try await cloud.renameCloudItem(file: file, newName: trimmed, credential: credential)
            container.toast.show("已重命名为「\(trimmed)」")
            await loadCurrentDirectory()
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }

    public func delete(file: ShareFile) async {
        guard let platform = selectedPlatform,
              let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else { return }

        isActing = true
        actionMessage = "正在删除…"
        defer {
            isActing = false
            actionMessage = nil
        }
        do {
            try await cloud.deleteCloudItems(files: [file], parentFid: currentDirFid, credential: credential)
            container.toast.show("已删除「\(file.fname)」")
            await loadCurrentDirectory()
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }

    public func download(file: ShareFile) async {
        guard !file.isdir,
              let platform = selectedPlatform,
              let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else { return }

        isActing = true
        actionMessage = "正在获取个人盘高速直链…"
        defer {
            isActing = false
            actionMessage = nil
        }
        do {
            let link = try await cloud.getCloudDownloadLink(file: file, credential: credential)
            let latestCredential = container.accountStore.credential(for: platform) ?? credential
            let headers = DownloadHeaderBuilder.buildHeaders(platform: platform, credential: latestCredential, link: link)
            container.downloadManager.enqueue(
                url: link.downloadUrl,
                fileName: link.filename.isEmpty ? file.fname : link.filename,
                headers: headers,
                size: link.size > 0 ? link.size : file.fsize,
                platform: DownloadPlatform(sharePlatform: platform)
            )
            container.toast.show("已加入高速下载队列")
            container.selectedTab = .download
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }

    // MARK: - 内部加载

    private func loadQuota(for platform: SharePlatform) async {
        guard let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else { return }
        let result = await cloud.fetchQuota(credential: credential)
        if selectedPlatform == platform {
            quota = result
        }
    }

    private func loadCurrentDirectory() async {
        guard let platform = selectedPlatform,
              let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let list = try await cloud.listCloudFiles(dirFid: currentDirFid, credential: credential)
            if selectedPlatform == platform {
                files = list.sorted { lhs, rhs in
                    if lhs.isdir != rhs.isdir { return lhs.isdir }
                    return lhs.fname.localizedStandardCompare(rhs.fname) == .orderedAscending
                }
            }
        } catch {
            if selectedPlatform == platform {
                errorMessage = error.localizedDescription
            }
        }
    }
}
