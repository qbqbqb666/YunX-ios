//
//  CreateShareSheet.swift
//  YunX
//
//  个人云盘创建分享弹窗：按平台展示有效期档位与提取码配置，创建后展示链接/提取码并支持一键复制。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CreateShareSheet: View {
    let container: AppContainer
    let platform: SharePlatform
    let file: ShareFile

    @Environment(\.dismiss) private var dismiss

    @State private var selectedExpire: CloudShareExpire = .sevenDays
    @State private var customPasscode: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var createdResult: CloudShareResult?

    private var expireOptions: [CloudShareExpire] {
        CloudShareExpire.options(for: platform)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result = createdResult {
                    resultView(result)
                } else {
                    configForm
                }
            }
            .navigationTitle(createdResult == nil ? "创建分享链接" : "分享创建成功")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(createdResult == nil ? "取消" : "完成") { dismiss() }
                }
            }
            .onAppear {
                if !expireOptions.contains(selectedExpire) {
                    selectedExpire = expireOptions.first ?? .forever
                }
            }
        }
    }

    private var configForm: some View {
        Form {
            Section("分享内容") {
                HStack(spacing: 10) {
                    FileTypeIconView(fileName: file.fname, isDir: file.isdir)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.fname)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        Text(platform.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("分享参数") {
                Picker("有效期", selection: $selectedExpire) {
                    ForEach(expireOptions) { opt in
                        Text(opt.displayTitle).tag(opt)
                    }
                }

                if platform.supportsCustomSharePasscode {
                    HStack {
                        TextField(
                            platform == .baidu ? "4 位提取码（留空自动生成）" : "自定义提取码（留空无提取码/默认）",
                            text: $customPasscode
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button("随机") {
                            customPasscode = SharePlatform.randomSharePasscode(length: 4)
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("\(platform.displayName)由服务端自动分配提取码，无需手动输入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    Task { await submitCreateShare() }
                } label: {
                    HStack {
                        Spacer()
                        if isCreating {
                            ProgressView()
                                .padding(.trailing, 6)
                        }
                        Text(isCreating ? "正在创建分享…" : "立即创建分享链接")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(isCreating)
            }
        }
    }

    private func resultView(_ result: CloudShareResult) -> some View {
        Form {
            Section("分享信息") {
                LabeledContent("平台", value: result.platform.displayName)
                LabeledContent("有效期", value: result.expire.displayTitle)
                VStack(alignment: .leading, spacing: 4) {
                    Text("分享链接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.shareUrl)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                if !result.passcode.isEmpty {
                    LabeledContent("提取码") {
                        Text(result.passcode)
                            .font(.headline.monospaced())
                            .foregroundStyle(Color.yunxBrand)
                    }
                }
            }

            if let warning = result.warning, !warning.isEmpty {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    copyText(result.formattedCopyText, toast: "已复制完整分享文案")
                } label: {
                    Label("复制分享链接与提取码", systemImage: "doc.on.doc.fill")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    copyText(result.shareUrl, toast: "已复制分享链接")
                } label: {
                    Label("仅复制链接", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func submitCreateShare() async {
        guard let cloud = container.cloudProvider(for: platform),
              let credential = container.accountStore.credential(for: platform) else {
            errorMessage = "请先在「账号」页登录\(platform.displayName)"
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let trimmed = customPasscode.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await cloud.createCloudShare(
                files: [file],
                title: file.fname,
                expire: selectedExpire,
                passcode: trimmed.isEmpty ? nil : trimmed,
                credential: credential
            )
            createdResult = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyText(_ text: String, toast: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        container.toast.show(toast)
    }
}
