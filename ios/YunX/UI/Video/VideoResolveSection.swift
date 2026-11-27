//
//  VideoResolveSection.swift
//  YunX
//
//  视频解析主界面（嵌于「解析」Tab 顶部分段切换内）：
//  - 输入态：整段分享文案粘贴、7 大平台自动识别徽章与支持概览；
//  - 结果态：作品封面、标题/作者/文案复制、逐条画质直链高速下载与图集一键批量入队。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct VideoResolveSection: View {
    let container: AppContainer
    @Bindable var viewModel: VideoResolveViewModel
    @State private var loginPlatform: VideoPlatform?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let result = viewModel.result {
                    resultSection(result)
                } else {
                    inputCard
                    if let err = viewModel.errorMessage {
                        errorBanner(err)
                    }
                    supportedVideoPlatformsCard
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $loginPlatform) { platform in
            VideoAccountLoginSheet(container: container, platform: platform)
        }
    }

    // MARK: - 输入卡片

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("粘贴视频 / 图文分享链接")
                    .font(.headline)
                Spacer()
                if let detected = viewModel.detectedLink {
                    videoPlatformBadge(detected.platform)
                }
            }

            TextField("支持整段分享文案（抖音 / 小红书 / 快手 / 微博 / B站 / AcFun / Pixiv）", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button {
                    #if canImport(UIKit)
                    if let str = UIPasteboard.general.string, !str.isEmpty {
                        viewModel.inputText = str
                    }
                    #endif
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)

                if !viewModel.inputText.isEmpty {
                    Button("清空") {
                        viewModel.inputText = ""
                        viewModel.reset()
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
                }
                Spacer()
            }

            Button {
                Task { await viewModel.startParse() }
            } label: {
                HStack {
                    if viewModel.isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.rectangle.fill")
                    }
                    Text(viewModel.isLoading ? "正在解析媒体直链…" : "开始视频解析")
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
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(err)
                .font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var supportedVideoPlatformsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前已支持 7 大视频 / 图文平台解析")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(VideoPlatform.allCases) { platform in
                    let loggedIn = container.videoAccountStore.isLoggedIn(platform)
                    Button {
                        if platform.needsLogin {
                            loginPlatform = platform
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: platform.symbolName)
                                .foregroundStyle(Color(hex: platform.brandHex))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(platform.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(platform.needsLogin ? (loggedIn ? "已登录" : "点击配置登录") : "免登录直解")
                                    .font(.caption2)
                                    .foregroundStyle(platform.needsLogin && loggedIn ? Color.yunxSuccess : .secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 解析结果卡片

    private func resultSection(_ result: VideoParseResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部返回与摘要
            HStack {
                Button {
                    viewModel.reset()
                } label: {
                    Label("重新解析", systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
                videoPlatformBadge(result.platform)
            }

            // 作品信息卡片
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    if !result.cover.isEmpty {
                        FileThumbnailView(
                            file: ShareFile(
                                fid: result.cover,
                                fname: "cover.jpg",
                                fsize: 0,
                                isdir: false,
                                thumbnail: FileThumbnail.secure(url: result.cover, headers: result.medias.first?.headers ?? [:])
                            ),
                            enabled: true,
                            size: 64,
                            cornerRadius: 12
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title.isEmpty ? "无标题作品" : result.title)
                            .font(.headline)
                            .lineLimit(3)
                        if !result.author.isEmpty {
                            Text("作者：\(result.author)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("共 \(result.medias.count) 项可下载媒体（视频 \(result.videoCount) / 图片 \(result.imageCount)）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !result.text.isEmpty && result.text != result.title {
                    Text(result.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                if !result.notice.isEmpty {
                    Label(result.notice, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    if result.medias.count > 1 {
                        Button {
                            viewModel.downloadAllMedias()
                        } label: {
                            Label("全部下载（\(result.medias.count)）", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !result.text.isEmpty || !result.title.isEmpty {
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = result.text.isEmpty ? result.title : result.text
                            #endif
                            container.toast.show("已复制作者文案")
                        } label: {
                            Label("复制文案", systemImage: "doc.on.doc")
                                .font(.subheadline)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(16)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            // 媒体直链列表
            VStack(alignment: .leading, spacing: 8) {
                Text("可下载直链")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(result.medias) { media in
                    mediaRow(media)
                }
            }
        }
    }

    private func mediaRow(_ media: VideoMedia) -> some View {
        HStack(spacing: 12) {
            FileThumbnailView(
                file: ShareFile(
                    fid: media.id,
                    fname: media.fileName.isEmpty ? (media.kind == .image ? "img.jpg" : "video.mp4") : media.fileName,
                    fsize: max(0, media.size),
                    isdir: false,
                    thumbnail: media.kind == .image ? FileThumbnail.secure(url: media.url, headers: media.headers) : nil
                ),
                enabled: container.settings.cloudThumbnailsEnabled
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(media.fileName.isEmpty ? media.kind.label : media.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !media.quality.isEmpty {
                        Text(media.quality)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.yunxBrand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yunxBrand.opacity(0.14), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    Text(media.isHls ? "HLS m3u8 流" : (media.size > 0 ? Formatters.fileSize(media.size) : media.kind.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !media.audioUrl.isEmpty {
                        Text("音视频分离（DASH）")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = media.url
                #endif
                container.toast.show("已复制媒体直链")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                viewModel.downloadMedia(media)
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.yunxBrand)
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func videoPlatformBadge(_ platform: VideoPlatform) -> some View {
        HStack(spacing: 5) {
            Image(systemName: platform.symbolName)
                .font(.caption2.weight(.semibold))
            Text(platform.displayName)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color(hex: platform.brandHex))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: platform.brandHex).opacity(0.14), in: Capsule())
    }
}
