//
//  ResolveView.swift
//  YunX
//
//  解析页主界面：
//  - 输入态：剪贴板自动识别提示、分享链接与提取码输入、平台支持总览、收藏快捷方式 4 列网格；
//  - 结果态：游客/登录态横幅、可点击面包屑导航、文件列表与底部操作弹窗。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ResolveView: View {
    let container: AppContainer
    @Bindable var viewModel: ResolveViewModel
    @State private var clipboardCandidate: ParsedShare?
    @State private var clipboardRawText: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if let session = viewModel.session {
                    sessionContentView(session: session)
                } else {
                    inputHomeView
                }
            }
            .navigationTitle(viewModel.session?.title ?? "云析 · 解析")
            .navigationBarTitleDisplayMode(viewModel.session == nil ? .large : .inline)
            .toolbar {
                if viewModel.session != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            viewModel.resetToInput()
                        } label: {
                            Label("返回", systemImage: "chevron.left")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.bookmarkCurrentShare()
                        } label: {
                            Image(systemName: "bookmark.fill")
                        }
                    }
                }
            }
            .sheet(item: $viewModel.selectedFileForSheet) { file in
                FileActionSheet(
                    file: file,
                    platform: viewModel.session?.platform ?? .quark,
                    onDownload: {
                        viewModel.selectedFileForSheet = nil
                        Task { await viewModel.fetchDirectLink(for: file) }
                    },
                    onDownloadFolder: {
                        viewModel.selectedFileForSheet = nil
                        Task { await viewModel.downloadFolder(file) }
                    }
                )
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: Binding(
                get: { viewModel.fetchedLink.map { IdentifiableDownloadLink(link: $0) } },
                set: { if $0 == nil { viewModel.dismissFetchedLink() } }
            )) { wrapper in
                DirectLinkSheet(
                    link: wrapper.link,
                    platform: viewModel.session?.platform ?? .quark,
                    onStartDownload: { viewModel.startDownload(link: wrapper.link) },
                    onCopyLink: {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = wrapper.link.downloadUrl
                        #endif
                        container.toast.show("已复制真实直链")
                    },
                    onClose: { viewModel.dismissFetchedLink() }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .overlay {
                if viewModel.isFetchingLink || viewModel.batchProgressText != nil {
                    loadingOverlay
                }
            }
            .onAppear {
                checkClipboardIfEnabled()
            }
        }
    }

    // MARK: - 输入主页态

    private var inputHomeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let detectedClip = clipboardCandidate {
                    clipboardBanner(detectedClip)
                }

                // 主输入卡片
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("粘贴网盘分享链接")
                            .font(.headline)
                        Spacer()
                        if let parsed = viewModel.detectedShare {
                            PlatformBadgeView(platform: parsed.platform, compact: true)
                        }
                    }

                    TextField("支持整段分享文案（自动提取链接与提取码）", text: $viewModel.inputText, axis: .vertical)
                        .lineLimit(3...5)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 10) {
                        TextField("提取码（可选，自动识别）", text: $viewModel.passcodeInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Button {
                            pasteFromClipboard()
                        } label: {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        Task { await viewModel.startResolve() }
                    } label: {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "bolt.fill")
                            }
                            Text(viewModel.isLoading ? "正在解析分享…" : "开始解析")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
                }
                .padding(16)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 2)

                if let err = viewModel.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                // 首批支持平台一览
                supportedPlatformsCard

                // 主页快捷方式（收藏）
                if !container.bookmarkStore.homePinnedItems.isEmpty {
                    shortcutsSection
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func clipboardBanner(_ parsed: ParsedShare) -> some View {
        HStack(spacing: 12) {
            PlatformBadgeView(platform: parsed.platform, compact: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到剪贴板分享链接")
                    .font(.subheadline.weight(.semibold))
                Text(parsed.rawUrl)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("解析") {
                let raw = clipboardRawText
                clipboardCandidate = nil
                Task { await viewModel.startResolve(overrideText: raw, overridePasscode: parsed.pwd) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.yunxBrand.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var supportedPlatformsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前已支持 10 大平台极速解析")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach([SharePlatform.quark, .uc, .pan123, .lanzou, .pan115, .c139, .xunlei, .guangya, .baidu, .github]) { platform in
                    HStack(spacing: 8) {
                        Image(systemName: platform.symbolName)
                            .foregroundStyle(Color(hex: platform.brandHex))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(platform.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(platform.supportsGuestDownload ? "支持免登录直下" : "需账号取直链")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("常用分享快捷方式")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 14) {
                ForEach(container.bookmarkStore.homePinnedItems) { item in
                    Button {
                        Task { await viewModel.startResolve(overrideText: item.link, overridePasscode: item.passcode) }
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(hex: item.platform.brandHex).opacity(0.16))
                                .frame(width: 52, height: 52)
                                .overlay {
                                    Text(item.tileLabel)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color(hex: item.platform.brandHex))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .padding(.horizontal, 4)
                                }
                            Text(item.title)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            container.bookmarkStore.remove(id: item.id)
                        } label: {
                            Label("删除收藏", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(14)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - 分享目录浏览态

    private func sessionContentView(session: ShareSession) -> some View {
        VStack(spacing: 0) {
            if viewModel.isGuestMode {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.yunxBrand)
                    Text(session.platform.guestNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.yunxBrand.opacity(0.08))
            }

            // 面包屑导航栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    PlatformBadgeView(platform: session.platform, compact: true)
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
                .padding(.vertical, 10)
            }
            .background(Color(.secondarySystemGroupedBackground))

            if viewModel.isLoading {
                Spacer()
                ProgressView("加载目录中…")
                Spacer()
            } else if viewModel.files.isEmpty {
                ContentUnavailableView("此目录为空", systemImage: "folder", description: Text("未发现文件或子目录"))
            } else {
                List(viewModel.files) { file in
                    HStack(spacing: 12) {
                        FileTypeIconView(fileName: file.fname, isDir: file.isdir)
                        VStack(alignment: .leading, spacing: 3) {
                            FileNameLabel(text: file.fname, multiLine: container.settings.fileNameMultiLine)
                            Text(file.isdir ? "文件夹" : Formatters.fileSize(file.fsize))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if file.isdir {
                            Button {
                                viewModel.selectedFileForSheet = file
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.title3)
                                .foregroundStyle(Color.yunxBrand)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if file.isdir {
                            Task { await viewModel.openFolder(file) }
                        } else {
                            viewModel.selectedFileForSheet = file
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(viewModel.batchProgressText ?? "正在获取真实高速直链…")
                    .font(.subheadline.weight(.medium))
                if viewModel.batchProgressText != nil {
                    Button("中断批量", role: .destructive) {
                        viewModel.cancelBatch()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func pasteFromClipboard() {
        #if canImport(UIKit)
        if let str = UIPasteboard.general.string, !str.isEmpty {
            viewModel.inputText = str
            if let parsed = ShareLinkParser.parse(str), let pwd = parsed.pwd, viewModel.passcodeInput.isEmpty {
                viewModel.passcodeInput = pwd
            }
        }
        #endif
    }

    private func checkClipboardIfEnabled() {
        guard container.settings.clipboardDetectEnabled, viewModel.session == nil else { return }
        #if canImport(UIKit)
        guard UIPasteboard.general.hasStrings,
              let text = UIPasteboard.general.string,
              text != viewModel.inputText,
              let parsed = ShareLinkParser.parse(text),
              parsed.platform.isSupported else {
            return
        }
        clipboardRawText = text
        clipboardCandidate = parsed
        #endif
    }
}

private struct IdentifiableDownloadLink: Identifiable {
    let id = UUID()
    let link: DownloadLink
}
