//
//  BackupSheetView.swift
//  YunX
//
//  账号加密备份导入/导出界面（PBKDF2 + AES-256-GCM，与 Android/PC 端 .yunx 文件完全互通）。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct BackupSheetView: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var mode = 0 // 0=导入, 1=导出
    @State private var password = ""
    @State private var importText = ""
    @State private var exportedText = ""
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("操作", selection: $mode) {
                        Text("导入备份").tag(0)
                        Text("导出加密备份").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == 0 {
                    Section {
                        TextField("粘贴 .yunx 密文或 JSON 内容", text: $importText, axis: .vertical)
                            .lineLimit(4...8)
                            .font(.caption.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("解密口令（明文 JSON 可留空）", text: $password)
                    } header: {
                        Text("从安卓 / PC / iOS 备份恢复")
                    } footer: {
                        Text("支持直接粘贴 Android 端导出的 YUNX_AUTH_V2 / V1 加密备份文本。")
                    }

                    Section {
                        Button("开始恢复账号") {
                            do {
                                let count = try container.backupService.importBackup(
                                    content: importText,
                                    password: password.isEmpty ? nil : password
                                )
                                container.toast.show("成功恢复 \(count) 个平台账号")
                                dismiss()
                            } catch {
                                statusMessage = error.localizedDescription
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Section {
                        SecureField("设置至少 8 位加密口令", text: $password)
                        Button("生成 AES-GCM 加密备份") {
                            do {
                                exportedText = try container.backupService.exportEncrypted(password: password)
                                statusMessage = "已生成兼容安卓/PC 端的加密备份，可复制妥善保存。"
                            } catch {
                                statusMessage = error.localizedDescription
                            }
                        }
                        .fontWeight(.semibold)
                        .disabled(password.count < 8)
                    }

                    if !exportedText.isEmpty {
                        Section("加密密文（YUNX_AUTH_V2）") {
                            Text(exportedText)
                                .font(.caption2.monospaced())
                                .lineLimit(5)
                                .textSelection(.enabled)
                            Button("复制加密文本") {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = exportedText
                                #endif
                                container.toast.show("已复制加密备份")
                            }
                        }
                    }
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("认证备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
