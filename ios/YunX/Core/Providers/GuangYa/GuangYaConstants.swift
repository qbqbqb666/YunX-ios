//
//  GuangYaConstants.swift
//  YunX
//
//  光鸭云盘协议常量、设备签名工具与结构化凭证载体。
//

import Foundation

public struct GuangYaCredentialPayload: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceId: String
    public var deviceSign: String
    public var account: String

    public init(
        accessToken: String,
        refreshToken: String = "",
        deviceId: String = GuangYaConstants.newDeviceId(),
        deviceSign: String = "",
        account: String = ""
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        let effectiveId = deviceId.isEmpty ? GuangYaConstants.newDeviceId() : deviceId
        self.deviceId = effectiveId
        self.deviceSign = deviceSign.isEmpty ? GuangYaConstants.newDeviceSign(deviceId: effectiveId) : deviceSign
        self.account = account
    }

    public func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return accessToken
        }
        return text
    }

    public static func decode(from raw: String) -> GuangYaCredentialPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(GuangYaCredentialPayload.self, from: data),
           !parsed.accessToken.isEmpty {
            return parsed
        }
        let bare = trimmed.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bare.isEmpty else { return nil }
        return GuangYaCredentialPayload(accessToken: bare)
    }
}

public enum GuangYaConstants {
    public static let clientId = "aMe-8VSlkrbQXpUR"
    public static let apiBase = "https://api.guangyapan.com"
    public static let accountBase = "https://account.guangyapan.com"
    public static let webSite = "https://www.guangyapan.com"
    public static let downloadReferer = "\(webSite)/"

    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    public static let clientVersion = "0.0.1"
    public static let sdkVersion = "9.1.3"
    public static let protocolVersion = "301"
    public static let deviceModel = "chrome%2F131.0.0.0"
    public static let deviceName = "PC-Chrome"
    public static let osVersion = "Win32"
    public static let platformVersion = "1"

    // 账号端点
    public static let authTokenURL = "\(accountBase)/v1/auth/token"
    public static let userMeURL = "\(accountBase)/v1/user/me"
    public static let captchaInitURL = "\(accountBase)/v1/shield/captcha/init"
    public static let signinURL = "\(accountBase)/v1/auth/signin"
    public static let signupURL = "\(accountBase)/v1/auth/signup"
    public static let verificationURL = "\(accountBase)/v1/auth/verification"
    public static let verificationVerifyURL = "\(accountBase)/v1/auth/verification/verify"

    // 业务端点
    public static let getAssetsURL = "\(apiBase)/assets/v1/get_assets"
    public static let shareSummaryURL = "\(apiBase)/userres/v1/get_share_summary"
    public static let shareAccessTokenURL = "\(apiBase)/userres/v1/get_share_access_token"
    public static let shareFilesURL = "\(apiBase)/userres/v1/get_share_page_files_list"
    public static let shareDownloadURL = "\(apiBase)/userres/v1/get_share_download_url"
    public static let restoreShareURL = "\(apiBase)/userres/v1/restore_share"
    public static let fileListURL = "\(apiBase)/userres/v1/file/get_file_list"
    public static let createDirURL = "\(apiBase)/userres/v1/file/create_dir"
    public static let renameURL = "\(apiBase)/userres/v1/file/rename"
    public static let moveFileURL = "\(apiBase)/userres/v1/file/move_file"
    public static let shareFileURL = "\(apiBase)/userres/v1/share_file"
    public static let deleteFileURL = "\(apiBase)/userres/v1/file/delete_file"
    public static let resDownloadURL = "\(apiBase)/userres/v1/get_res_download_url"
    public static let uploadTokenURL = "\(apiBase)/nd.bizuserres.s/v1/get_res_center_token"
    public static let uploadTaskInfoURL = "\(apiBase)/nd.bizuserres.s/v1/file/get_info_by_task_id"
    public static let uploadPendingCodes: Set<String> = ["145", "146", "147", "155", "163"]
    public static let taskStatusURL = "\(apiBase)/userres/v1/get_task_status"

    public static let pageSize = 100
    public static let tempDirName = "YunX临时转存"

    public static func newDeviceId() -> String { randomHex(32) }

    public static func newDeviceSign(deviceId: String) -> String {
        "wdi10.\(deviceId)\(randomHex(32))"
    }

    public static func deviceIdFromSign(_ deviceSign: String, fallback: String) -> String {
        guard let dot = deviceSign.firstIndex(of: ".") else { return fallback }
        let rest = deviceSign[deviceSign.index(after: dot)...]
        return rest.count >= 32 ? String(rest.prefix(32)) : fallback
    }

    public static func newTraceparent() -> String {
        "00-\(randomHex(32))-\(randomHex(16))-01"
    }

    public static func normalizeAccount(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        let digits = s.filter(\.isNumber)
        if s.hasPrefix("+86") {
            let body = digits.hasPrefix("86") ? String(digits.dropFirst(2)) : digits
            return "+86 \(body)"
        }
        if s.count == 11 && s.allSatisfy(\.isNumber) {
            return "+86 \(s)"
        }
        return s
    }

    private static func randomHex(_ count: Int) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<count).map { _ in chars[Int.random(in: 0..<16)] })
    }
}
