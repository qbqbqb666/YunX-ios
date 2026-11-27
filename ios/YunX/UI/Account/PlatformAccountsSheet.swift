//
//  PlatformAccountsSheet.swift
//  YunX
//
//  单平台多账号管理弹窗：查看同平台全部已保存账号、一键切换活跃主账号、修改备注、添加新账号或退出单个账号。
//

import SwiftUI

struct PlatformAccountsSheet: View {
    let container: AppContainer
    let platform: SharePlatform
    let onAddAccount: () -> Void
    let onManualAdd: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var remarkTarget: AccountRecord?
    @State private var remarkInput: String = ""

    private var items: [AccountRecord] {
        container.accountStore.accounts(for: platform)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        ContentUnavailableView("暂无已登录账号", systemImage: "person.crop.circle.badge.questionmark")
                    } else {
                        ForEach(items) { item in
                            accountSlotRow(item)
                        }
                    }
                } header: {
                    Text("已保存账号（\(items.count)）")
                } footer: {
                    Text("点击任意账号即可切换为当前活跃账号，个人云盘浏览、转存与分享解析将自动使用当前活跃账号。")
                }

                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onAddAccount()
                        }
                    } label: {
                        Label("添加新账号（登录）", systemImage: "person.badge.plus")
                    }

                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            onManualAdd()
                        }
                    } label: {
                        Label("手动粘贴新增凭证", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("\(platform.displayName) · 多账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("修改账号备注", isPresented: Binding(
                get: { remarkTarget != nil },
                set: { if !$0 { remarkTarget = nil } }
            )) {
                TextField("如：主号 / 会员号 / 小号", text: $remarkInput)
                Button("取消", role: .cancel) { remarkTarget = nil }
                Button("保存") {
                    if let target = remarkTarget {
                        container.accountStore.updateRemark(accountId: target.id, remark: remarkInput)
                        remarkTarget = nil
                    }
                }
            }
        }
    }

    private func accountSlotRow(_ item: AccountRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isPrimary ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(item.isPrimary ? Color.yunxSuccess : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayTitle)
                        .font(.body.weight(item.isPrimary ? .semibold : .regular))
                    if item.isPrimary {
                        Text("当前使用")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.yunxSuccess)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yunxSuccess.opacity(0.14), in: Capsule())
                    }
                }
                if !item.remark.isEmpty && !item.nickname.isEmpty && item.remark != item.nickname {
                    Text("昵称：\(item.nickname)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !item.accountIdentifier.isEmpty && item.accountIdentifier != item.displayTitle {
                    Text(item.accountIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                if !item.isPrimary {
                    Button {
                        container.accountStore.setPrimary(accountId: item.id, for: platform)
                        container.toast.show("已切换\(platform.displayName)为「\(item.displayTitle)」")
                    } label: {
                        Label("设为当前账号", systemImage: "checkmark.circle")
                    }
                }
                Button {
                    remarkInput = item.remark
                    remarkTarget = item
                } label: {
                    Label("修改备注", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive) {
                    container.accountStore.removeAccount(id: item.id)
                    container.toast.show("已移除账号「\(item.displayTitle)」")
                } label: {
                    Label("移除该账号", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !item.isPrimary {
                container.accountStore.setPrimary(accountId: item.id, for: platform)
                container.toast.show("已切换\(platform.displayName)为「\(item.displayTitle)」")
            }
        }
    }
}
