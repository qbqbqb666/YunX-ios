//
//  AuthBackupService.swift
//  YunX
//
//  账号凭证加密备份导入/导出服务（与 Android AuthBackupManager JSON Schema 完全兼容）。
//

import Foundation

public enum AuthBackupError: LocalizedError, Sendable {
    case invalidFormat
    case passwordRequired

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "不是有效的云析账号备份文件"
        case .passwordRequired: return "该备份文件已加密，请输入备份口令"
        }
    }
}

@MainActor
public final class AuthBackupService {
    private let accountStore: AccountStore
    private static let appTag = "yunx_auth_backup"

    public init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    /// 导出加密备份文本（`.yunx` 格式，可直接在 Android / PC / iOS 之间互通）
    public func exportEncrypted(password: String) throws -> String {
        let json = try exportJSON()
        return try AuthCrypto.encrypt(plaintext: json, password: password)
    }

    public func exportJSON() throws -> String {
        var accountDicts: [[String: Any]] = []
        var githubToken: String = ""
        for platform in SharePlatform.allCases {
            guard let cred = accountStore.credential(for: platform), !cred.isEmpty else { continue }
            let record = accountStore.record(for: platform)
            if platform == .github {
                githubToken = cred
                continue
            }
            var item: [String: Any] = [
                "platform": platform.backupKey,
                "nickname": record?.nickname ?? "",
                "updatedAt": record?.updatedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
            ]
            switch platform {
            case .pan123:
                item["accessToken"] = cred
                item["account"] = record?.accountIdentifier ?? ""
            case .xunlei:
                if let p = XunleiCredentialPayload.decode(from: cred) {
                    item["accessToken"] = p.accessToken
                    item["refreshToken"] = p.refreshToken
                    item["deviceId"] = p.deviceId
                    item["captchaToken"] = p.captchaToken
                    item["authType"] = p.authType
                } else {
                    item["accessToken"] = cred
                }
            case .guangya:
                if let p = GuangYaCredentialPayload.decode(from: cred) {
                    item["accessToken"] = p.accessToken
                    item["refreshToken"] = p.refreshToken
                    item["deviceId"] = p.deviceId
                    item["deviceSign"] = p.deviceSign
                    item["account"] = p.account
                } else {
                    item["accessToken"] = cred
                }
            case .c139:
                item["cookie"] = cred
                if let auth = C139Constants.extractAuthorization(cred) {
                    item["authorization"] = auth
                }
            case .ilanzou:
                item["appToken"] = cred
            default:
                item["cookie"] = cred
            }
            accountDicts.append(item)
        }
        var root: [String: Any] = [
            "app": Self.appTag,
            "version": 1,
            "exportedAt": Int64(Date().timeIntervalSince1970 * 1000),
            "accounts": accountDicts
        ]
        if !githubToken.isEmpty {
            root["githubToken"] = githubToken
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 导入备份文本（自动识别明文 JSON 或 AES-GCM 加密 `.yunx` 文本），返回恢复的平台数量
    @discardableResult
    public func importBackup(content: String, password: String?) throws -> Int {
        let jsonText: String
        if AuthCrypto.isEncrypted(content) {
            guard let pwd = password, !pwd.isEmpty else {
                throw AuthBackupError.passwordRequired
            }
            jsonText = try AuthCrypto.decrypt(base64Data: content, password: pwd)
        } else {
            jsonText = content
        }
        return try importJSON(jsonText)
    }

    @discardableResult
    public func importJSON(_ jsonText: String) throws -> Int {
        guard let data = jsonText.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["app"] as? String) == Self.appTag,
              let accounts = root["accounts"] as? [[String: Any]] else {
            throw AuthBackupError.invalidFormat
        }
        var restored = 0
        for obj in accounts {
            guard let rawPlatform = obj["platform"] as? String else { continue }
            if rawPlatform.hasPrefix("video:") { continue } // Phase 3 视频账号支持时接管
            guard let platform = SharePlatform(rawValue: rawPlatform) else { continue }
            let nickname = obj["nickname"] as? String ?? ""
            let updatedAt = (obj["updatedAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)

            let credential: String?
            let accountId = obj["account"] as? String ?? ""
            switch platform {
            case .pan123:
                credential = obj["accessToken"] as? String
            case .xunlei:
                if let at = obj["accessToken"] as? String, !at.isEmpty {
                    let payload = XunleiCredentialPayload(
                        accessToken: at,
                        refreshToken: obj["refreshToken"] as? String ?? "",
                        deviceId: obj["deviceId"] as? String ?? "",
                        captchaToken: obj["captchaToken"] as? String ?? "",
                        authType: obj["authType"] as? String ?? ""
                    )
                    credential = payload.encodedString()
                } else {
                    credential = nil
                }
            case .guangya:
                if let at = obj["accessToken"] as? String, !at.isEmpty {
                    let payload = GuangYaCredentialPayload(
                        accessToken: at,
                        refreshToken: obj["refreshToken"] as? String ?? "",
                        deviceId: obj["deviceId"] as? String ?? "",
                        deviceSign: obj["deviceSign"] as? String ?? "",
                        account: accountId
                    )
                    credential = payload.encodedString()
                } else {
                    credential = nil
                }
            case .c139:
                let cookie = obj["cookie"] as? String ?? ""
                let auth = obj["authorization"] as? String ?? ""
                if !cookie.isEmpty {
                    credential = (cookie.contains("authorization=") || auth.isEmpty) ? cookie : "\(cookie); authorization=\(auth)"
                } else if !auth.isEmpty {
                    credential = "authorization=\(auth)"
                } else {
                    credential = nil
                }
            case .ilanzou:
                credential = obj["appToken"] as? String
            default:
                credential = obj["cookie"] as? String
            }

            if let cred = credential, !cred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                accountStore.saveAccount(
                    platform: platform,
                    credential: cred,
                    nickname: nickname,
                    accountIdentifier: accountId,
                    updatedAt: updatedAt
                )
                restored += 1
            }
        }
        if let ghToken = root["githubToken"] as? String, !ghToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            accountStore.saveAccount(platform: .github, credential: ghToken.trimmingCharacters(in: .whitespacesAndNewlines), nickname: "GitHub Token")
            restored += 1
        }
        return restored
    }
}
