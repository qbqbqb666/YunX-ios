//
//  GuangYaLoginView.swift
//  YunX
//
//  光鸭云盘原生登录界面：支持账号密码登录、短信验证码登录与手动 Token 导入。
//

import SwiftUI

struct GuangYaLoginView: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    enum LoginMode: String, CaseIterable {
        case password = "账号密码"
        case sms = "短信验证码"
    }

    @State private var mode: LoginMode = .password
    @State private var account = ""
    @State private var password = ""
    @State private var smsCode = ""
    @State private var smsChallenge: GuangYaSmsChallenge?
    @State private var isSubmitting = false
    @State private var errorMsg: String?
    @State private var showManualSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("登录方式", selection: $mode) {
                        ForEach(LoginMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .password {
                    Section {
                        TextField("手机号 / 邮箱 / 用户名", text: $account)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("登录密码", text: $password)
                    } header: {
                        Text("光鸭云盘账号密码登录")
                    } footer: {
                        Text("公开分享支持免登录直下；登录账号后可解锁受限分享（207）的自动转存下载。")
                    }
                } else {
                    Section {
                        TextField("11 位手机号", text: $account)
                            .keyboardType(.phonePad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            TextField("短信验证码", text: $smsCode)
                                .keyboardType(.numberPad)
                            Button(smsChallenge != nil ? "重新发送" : "获取验证码") {
                                Task { await requestSms() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                        }
                    } header: {
                        Text("光鸭短信验证码登录 / 注册")
                    }
                }

                if let errorMsg {
                    Section {
                        Text(errorMsg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting { ProgressView() }
                            else { Text("登录光鸭云盘").fontWeight(.semibold) }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }

                Section("备用登录方式") {
                    Button {
                        showManualSheet = true
                    } label: {
                        Label("手动粘贴 Access Token", systemImage: "doc.on.clipboard")
                    }
                }
            }
            .navigationTitle("登录光鸭云盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showManualSheet) {
                ManualCookieSheet(container: container, platform: .guangya) {
                    dismiss()
                }
            }
        }
    }

    private var canSubmit: Bool {
        let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .password {
            return !acc.isEmpty && !password.isEmpty
        }
        return !acc.isEmpty && !smsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && smsChallenge != nil
    }

    private func requestSms() async {
        let phone = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else { return }
        isSubmitting = true
        errorMsg = nil
        defer { isSubmitting = false }
        do {
            let challenge = try await container.guangyaProvider.sendSmsCode(phoneNumber: phone)
            smsChallenge = challenge
            container.toast.show("验证码已发送")
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func submit() async {
        let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        errorMsg = nil
        defer { isSubmitting = false }
        do {
            let result: (payload: GuangYaCredentialPayload, nickname: String)
            if mode == .password {
                result = try await container.guangyaProvider.signIn(username: acc, password: password)
            } else {
                guard let challenge = smsChallenge else { return }
                result = try await container.guangyaProvider.completeSmsLogin(
                    phoneNumber: acc,
                    smsCode: smsCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    challenge: challenge
                )
            }
            container.accountStore.saveAccount(
                platform: .guangya,
                credential: result.payload.encodedString(),
                nickname: result.nickname,
                accountIdentifier: result.payload.account
            )
            container.toast.show("光鸭云盘登录成功：\(result.nickname)")
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
