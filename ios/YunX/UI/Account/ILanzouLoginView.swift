//
//  ILanzouLoginView.swift
//  YunX
//
//  蓝奏优享版原生账号密码登录表单。
//

import SwiftUI

struct ILanzouLoginView: View {
    let container: AppContainer
    var asNewAccount: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var account: String = ""
    @State private var password: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("手机号 / 邮箱", text: $account)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                } header: {
                    Text("蓝奏优享账号")
                } footer: {
                    Text("蓝奏优享分享链接默认支持免登录匿名解析与下载；登录账号后下载通道更稳定，凭证仅存于本机 Keychain。")
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
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView().padding(.trailing, 6) }
                            Text(isSubmitting ? "正在登录…" : "登录蓝奏优享")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting || account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("登录蓝奏优享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let (payload, nickname) = try await container.ilanzouProvider.login(loginName: account, loginPwd: password)
            container.accountStore.saveAccount(
                platform: .ilanzou,
                credential: payload.encodedString(),
                nickname: nickname,
                accountIdentifier: payload.account,
                asNewAccount: asNewAccount
            )
            container.toast.show("蓝奏优享已登录：\(nickname)")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
