//
//  FileActionSheet.swift
//  YunX
//
//  解析页文件操作底部弹窗与直链确认弹窗。
//

import SwiftUI

struct FileActionSheet: View {
    let file: ShareFile
    let platform: SharePlatform
    let onDownload: () -> Void
    let onDownloadFolder: () -> Void
    let onTransferToCloud: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FileTypeIconView(fileName: file.fname, isDir: file.isdir)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.fname)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        PlatformBadgeView(platform: platform, compact: true)
                        Text(file.isdir ? "文件夹" : Formatters.fileSize(file.fsize))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            if file.isdir {
                Button(action: onDownloadFolder) {
                    Label("高速下载整个文件夹", systemImage: "folder.badge.plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: onDownload) {
                    Label("获取直链并高速下载", systemImage: "bolt.horizontal.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }

            if let onTransferToCloud, platform.supportsCloudDrive {
                Button(action: onTransferToCloud) {
                    Label("转存到我的\(platform.displayName)", systemImage: "tray.and.arrow.down.fill")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(20)
    }
}

struct DirectLinkSheet: View {
    let link: DownloadLink
    let platform: SharePlatform
    let onStartDownload: () -> Void
    let onCopyLink: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    FileTypeIconView(fileName: link.filename, isDir: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.filename)
                            .font(.headline)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            PlatformBadgeView(platform: platform, compact: true)
                            Text(Formatters.fileSize(link.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !link.guestCookie.isEmpty {
                                Text("游客直链")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("真实直链地址")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(link.downloadUrl)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(spacing: 12) {
                    Button(action: onCopyLink) {
                        Label("复制直链", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onStartDownload) {
                        Label("多线程下载", systemImage: "arrow.down.circle.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("直链解析成功")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose)
                }
            }
        }
    }
}
