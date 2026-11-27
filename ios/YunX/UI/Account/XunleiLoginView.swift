//
//  XunleiLoginView.swift
//  YunX
//
//  迅雷网盘原生登录界面：支持短信验证码登录、账号密码登录与手动 Token 导入。
//

import SwiftUI

struct XunleiLoginView: View {
    let container: AppContainer
    @Environment(\.dismiss) private var dismiss

    enum LoginMode: String, CaseIterable {
        case sms = "短信验证码"
        case password = "账号密码"
    }

    @State private var mode: LoginMode = .sms
    @State private var account = ""
    @State private var password = ""
    @State private var smsCode = ""
    @State private var smsCreditKey = ""
    @State private var smsToken = ""
    @State private var smsSent = false
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

                if mode == .sms {
                    Section {
                        TextField("迅雷绑定手机号", text: $account)
                            .keyboardType(.phonePad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            TextField("短信验证码", text: $smsCode)
                                .keyboardType(.numberPad)
                            Button(smsSent ? "重新发送" : "获取验证码") {
                                Task { await requestSms() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                        }
                    } header: {
                        Text("短信登录（推荐，避开新设备密码风控）")
                    } footer: {
                        Text("迅雷下载并发将自动固定为 8 线程并使用客户端 UA，防止限流。")
                    }
                } else {
                    Section {
                        TextField("手机号 / 账号", text: $account)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("登录密码", text: $password)
                    } header: {
                        Text("迅雷官方账号登录")
                    } footer: {
                        Text("首次在新设备使用密码登录时，迅雷可能触发二次验证，建议直接切换「短信验证码」登录。")
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
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("登录迅雷网盘").fontWeight(.semibold)
                            }
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
            .navigationTitle("登录迅雷网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showManualSheet) {
                ManualCookieSheet(container: container, platform: .xunlei) {
                    dismiss()
                }
            }
        }
    }

    private var canSubmit: Bool {
        let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .sms {
            return !acc.isEmpty && !smsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !smsToken.isEmpty
        }
        return !acc.isEmpty && !password.isEmpty
    }

    private func requestSms() async {
        let mobile = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mobile.isEmpty else { return }
        isSubmitting = true
        errorMsg = nil
        defer { isSubmitting = false }
        do {
            let step = try await container.xunleiProvider.sendSms(mobile: mobile)
            smsCreditKey = step.smsCreditKey
            smsToken = step.smsToken
            if !smsToken.isEmpty {
                smsSent = true
                container.toast.show("验证码已发送至 \(mobile)")
            } else {
                errorMsg = step.message
            }
        } catch {
            errorMsg = error.localizedDescription
        }
    }

    private func submit() async {
        let acc = account.trimmingCharacters(in: .whitespacesAndNewlines)
        isSubmitting = true
        errorMsg = nil
        defer { isSubmitting = false }
        let deviceId = XunleiSigner.deviceId()
        do {
            let step: XunleiLoginStep
            if mode == .sms {
                step = try await container.xunleiProvider.smsLogin(
                    mobile: acc,
                    smsCode: smsCode.trimmingCharacters(in: .whitespacesAndNewlines),
                    creditKey: smsCreditKey,
                    smsToken: smsToken
                )
            } else {
                step = try await container.xunleiProvider.loginWithPassword(
                    username: acc,
                    password: password,
                    deviceId: deviceId
                )
            }

            if step.needSms {
                mode = .sms
                errorMsg = "当前设备需要短信二次验证，请点击「获取验证码」完成登录"
                return
            }
            guard !step.sessionId.isEmpty else {
                errorMsg = step.message
                return
            }

            let payload = try await container.xunleiProvider.exchangeToken(
                sessionId: step.sessionId,
                deviceId: deviceId,
                userId: step.userID,
                username: acc
            )
            let nick = step.nickname.isEmpty ? acc : step.nickname
            container.accountStore.saveAccount(
                platform: .xunlei,
                credential: payload.encodedString(),
                nickname: nick,
                accountIdentifier: acc
            )
            container.toast.show("迅雷登录成功：\(nick)")
            dismiss()
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}
