//
//  Pan123LoginView.swift
//  YunX
//
//  123 云盘原生账号密码登录界面（支持切换官方网页登录与手动粘贴 authorToken）。
//

import SwiftUI

struct Pan123LoginView: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    @State private var account = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showWebLogin = false
    @State private var showManualToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("手机号或邮箱", text: $account)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                } header: {
                    Text("账号密码直登")
                } footer: {
                    Text("直连官方认证接口 user.123pan.cn 换取 Bearer JWT，密码不会被保存。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submitLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("登录 123 云盘")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isSubmitting)
                }

                Section("其他登录方式") {
                    Button {
                        showWebLogin = true
                    } label: {
                        Label("使用官方网页登录（触发风控验证时推荐）", systemImage: "safari")
                    }
                    Button {
                        showManualToken = true
                    } label: {
                        Label("手动粘贴 authorToken", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("登录 123 云盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showWebLogin) {
                WebLoginView(container: container, platform: .pan123)
            }
            .sheet(isPresented: $showManualToken) {
                ManualCookieSheet(container: container, platform: .pan123) {
                    dismiss()
                }
            }
        }
    }

    private func submitLogin() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            let token = try await container.pan123Provider.passwordLogin(account: account, password: password)
            let nick = await container.pan123Provider.fetchNickname(credential: token) ?? account.trimmingCharacters(in: .whitespaces)
            container.accountStore.saveAccount(
                platform: .pan123,
                credential: token,
                nickname: nick,
                accountIdentifier: account.trimmingCharacters(in: .whitespaces)
            )
            container.toast.show("123 云盘登录成功：\(nick)")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
