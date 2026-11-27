//
//  ResolveViewModel.swift
//  YunX
//
//  解析页状态机：自动识别平台、会话与目录面包屑导航、游客/登录态取直链、单文件与文件夹递归批量入队。
//

import Foundation
import Observation

public struct BreadcrumbNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

@MainActor
@Observable
public final class ResolveViewModel {
    public var inputText: String = ""
    public var passcodeInput: String = ""

    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var session: ShareSession?
    public private(set) var files: [ShareFile] = []
    public private(set) var breadcrumbs: [BreadcrumbNode] = []
    public private(set) var isGuestMode: Bool = false

    /// 正在取直链的加载态
    public private(set) var isFetchingLink: Bool = false
    public var fetchedLink: DownloadLink?
    public var selectedFileForSheet: ShareFile?

    /// 批量/文件夹下载进度文案
    public private(set) var batchProgressText: String?

    private let container: AppContainer
    private var batchCancelled = false

    public var detectedShare: ParsedShare? {
        ShareLinkParser.parse(inputText)
    }

    public init(container: AppContainer) {
        self.container = container
    }

    // MARK: - 启动分享解析

    public func startResolve(overrideText: String? = nil, overridePasscode: String? = nil) async {
        if let overrideText { inputText = overrideText }
        if let overridePasscode { passcodeInput = overridePasscode }

        guard let parsed = ShareLinkParser.parse(inputText) else {
            errorMessage = ProviderError.unrecognizedLink.localizedDescription
            return
        }
        guard let provider = container.provider(for: parsed.platform) else {
            errorMessage = ProviderError.platformNotYetSupported(parsed.platform).localizedDescription
            return
        }

        isLoading = true
        errorMessage = nil
        fetchedLink = nil
        selectedFileForSheet = nil

        let credential = container.accountStore.credential(for: parsed.platform) ?? ""
        isGuestMode = credential.isEmpty

        let effectivePwd = passcodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? parsed.pwd
            : passcodeInput.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let newSession = try await provider.createSession(parsed: parsed, pwd: effectivePwd, credential: credential)
            let rootFid = parsed.platform.rootDirFid
            let rootFiles = try await provider.listFiles(session: newSession, dirFid: rootFid, credential: credential)
            self.session = newSession
            self.breadcrumbs = [BreadcrumbNode(id: rootFid, name: newSession.title)]
            self.files = Self.sortedFiles(rootFiles)
        } catch {
            var msg = error.localizedDescription
            if isGuestMode {
                msg += "\n（当前未登录，可先在「账号」页登录\(parsed.platform.displayName)后重试）"
            }
            errorMessage = msg
        }
        isLoading = false
    }

    public func openFolder(_ file: ShareFile) async {
        guard file.isdir, let session, let provider = container.provider(for: session.platform) else { return }
        isLoading = true
        errorMessage = nil
        let credential = container.accountStore.credential(for: session.platform) ?? ""
        do {
            let list = try await provider.listFiles(session: session, dirFid: file.fid, credential: credential)
            breadcrumbs.append(BreadcrumbNode(id: file.fid, name: file.fname))
            files = Self.sortedFiles(list)
        } catch {
            container.toast.show(error.localizedDescription)
        }
        isLoading = false
    }

    public func navigateToBreadcrumb(index: Int) async {
        guard index >= 0, index < breadcrumbs.count - 1,
              let session, let provider = container.provider(for: session.platform) else { return }
        let target = breadcrumbs[index]
        isLoading = true
        let credential = container.accountStore.credential(for: session.platform) ?? ""
        do {
            let list = try await provider.listFiles(session: session, dirFid: target.id, credential: credential)
            breadcrumbs = Array(breadcrumbs.prefix(index + 1))
            files = Self.sortedFiles(list)
        } catch {
            container.toast.show(error.localizedDescription)
        }
        isLoading = false
    }

    public func resetToInput() {
        session = nil
        files = []
        breadcrumbs = []
        errorMessage = nil
        fetchedLink = nil
        selectedFileForSheet = nil
        isGuestMode = false
    }

    public func bookmarkCurrentShare() {
        guard let session else { return }
        container.bookmarkStore.add(
            link: session.originalLink,
            title: session.title,
            platform: session.platform,
            passcode: session.passcode ?? ""
        )
        container.toast.show("已收藏并固定到解析主页")
    }

    // MARK: - 取直链与入队下载

    public func fetchDirectLink(for file: ShareFile) async {
        guard let session, let provider = container.provider(for: session.platform) else { return }
        isFetchingLink = true
        fetchedLink = nil
        defer { isFetchingLink = false }

        do {
            let link = try await resolveDownloadLink(provider: provider, session: session, file: file)
            fetchedLink = link
        } catch {
            container.toast.show(error.localizedDescription)
        }
    }

    public func startDownload(link: DownloadLink) {
        guard let session else { return }
        enqueueSingleLink(link, platform: session.platform, customFileName: nil)
        fetchedLink = nil
        container.toast.show("已加入高速下载队列")
        container.selectedTab = .download
    }

    public func dismissFetchedLink() {
        guard let link = fetchedLink, let session else {
            fetchedLink = nil
            return
        }
        fetchedLink = nil
        // 若用户取消了本次下载，清理夸克等平台的临时转存子目录
        if let cleanupFid = link.cleanupDirFid,
           let provider = container.provider(for: session.platform),
           let credential = container.accountStore.credential(for: session.platform) {
            Task.detached {
                await provider.cleanupTempDir(dirFid: cleanupFid, credential: credential)
            }
        }
    }

    /// 递归下载整个文件夹（保留目录层级并在下载页自动折叠成文件夹组）
    public func downloadFolder(_ folder: ShareFile) async {
        guard folder.isdir, let session, let provider = container.provider(for: session.platform) else { return }
        batchCancelled = false
        batchProgressText = "正在扫描文件夹内容…"
        defer { batchProgressText = nil }

        let credential = container.accountStore.credential(for: session.platform) ?? ""
        if credential.isEmpty && !session.platform.supportsGuestDownload {
            container.toast.show("下载需先到「账号」页登录\(session.platform.displayName)")
            return
        }

        var collected: [(file: ShareFile, relPath: String)] = []
        await collectFolderRecursive(
            provider: provider,
            session: session,
            dirFid: folder.fid,
            prefix: folder.fname,
            credential: credential,
            depth: 0,
            into: &collected
        )

        guard !collected.isEmpty else {
            container.toast.show("该文件夹下没有可下载的文件")
            return
        }

        var okCount = 0
        var failCount = 0
        for (idx, item) in collected.enumerated() {
            if batchCancelled { break }
            batchProgressText = "正在取直链 \(idx + 1)/\(collected.count)"
            do {
                let link = try await resolveDownloadLink(provider: provider, session: session, file: item.file)
                enqueueSingleLink(link, platform: session.platform, customFileName: item.relPath)
                okCount += 1
            } catch {
                failCount += 1
            }
        }

        if okCount > 0 {
            let msg = failCount == 0 ? "已添加 \(okCount) 个文件到下载队列" : "已添加 \(okCount) 个，失败 \(failCount) 个"
            container.toast.show(msg)
            container.selectedTab = .download
        } else {
            container.toast.show("文件夹内所有文件取链均失败")
        }
    }

    public func cancelBatch() {
        batchCancelled = true
    }

    // MARK: - 内部工具

    private func resolveDownloadLink(
        provider: ShareResolveProvider,
        session: ShareSession,
        file: ShareFile
    ) async throws -> DownloadLink {
        let credential = container.accountStore.credential(for: session.platform) ?? ""
        if credential.isEmpty {
            guard session.platform.supportsGuestDownload else {
                throw ProviderError.loginRequired(session.platform)
            }
            let link = try await provider.getGuestShareDownloadLink(session: session, file: file)
            return link.filename.isEmpty ? link.withFilename(file.fname) : link
        }
        let link = try await provider.getShareDownloadLink(
            session: session,
            file: file,
            credential: credential,
            preferNoSave: container.settings.quarkNoSaveDownload
        )
        return link.filename.isEmpty ? link.withFilename(file.fname) : link
    }

    private func enqueueSingleLink(_ link: DownloadLink, platform: SharePlatform, customFileName: String?) {
        let latestCredential = container.accountStore.credential(for: platform) ?? ""
        let headers = DownloadHeaderBuilder.buildHeaders(platform: platform, credential: latestCredential, link: link)
        let cleanupFid = link.cleanupDirFid
        let provider = container.provider(for: platform)
        let cleanupAction: (@Sendable () async -> Void)? = {
            guard let cleanupFid, let provider, !latestCredential.isEmpty else { return nil }
            return {
                await provider.cleanupTempDir(dirFid: cleanupFid, credential: latestCredential)
            }
        }()

        container.downloadManager.enqueue(
            url: link.downloadUrl,
            fileName: customFileName ?? link.filename,
            headers: headers,
            size: link.size,
            platform: DownloadPlatform(sharePlatform: platform),
            onFinishCleanup: cleanupAction
        )
    }

    private func collectFolderRecursive(
        provider: ShareResolveProvider,
        session: ShareSession,
        dirFid: String,
        prefix: String,
        credential: String,
        depth: Int,
        into out: inout [(file: ShareFile, relPath: String)]
    ) async {
        guard depth <= 8, !batchCancelled else { return }
        guard let children = try? await provider.listFiles(session: session, dirFid: dirFid, credential: credential) else {
            return
        }
        for child in children {
            if batchCancelled { return }
            let nextPath = "\(prefix)/\(child.fname)"
            if child.isdir {
                await collectFolderRecursive(
                    provider: provider,
                    session: session,
                    dirFid: child.fid,
                    prefix: nextPath,
                    credential: credential,
                    depth: depth + 1,
                    into: &out
                )
            } else {
                out.append((child, nextPath))
            }
        }
    }

    private static func sortedFiles(_ list: [ShareFile]) -> [ShareFile] {
        list.sorted { lhs, rhs in
            if lhs.isdir != rhs.isdir { return lhs.isdir }
            return lhs.fname.localizedStandardCompare(rhs.fname) == .orderedAscending
        }
    }
}
