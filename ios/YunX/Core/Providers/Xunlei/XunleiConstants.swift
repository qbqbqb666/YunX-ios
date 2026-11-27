//
//  XunleiConstants.swift
//  YunX
//
//  迅雷网盘协议常量与结构化凭证载体（兼容纯 accessToken 字符串与多字段 JSON）。
//

import Foundation

public struct XunleiCredentialPayload: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceId: String
    public var captchaToken: String
    public var authType: String

    public init(
        accessToken: String,
        refreshToken: String = "",
        deviceId: String = "",
        captchaToken: String = "",
        authType: String = ""
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
        self.captchaToken = captchaToken
        self.authType = authType
    }

    public func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return accessToken
        }
        return text
    }

    /// 自动兼容 JSON 载体与纯 accessToken 字符串
    public static func decode(from raw: String) -> XunleiCredentialPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(XunleiCredentialPayload.self, from: data),
           !parsed.accessToken.isEmpty {
            return parsed
        }
        let bare = trimmed.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bare.isEmpty else { return nil }
        return XunleiCredentialPayload(accessToken: bare, deviceId: XunleiSigner.deviceId())
    }
}

public enum XunleiConstants {
    public static let authBase = "https://xluser-ssl.xunlei.com"
    public static let panBase = "https://api-pan.xunlei.com"

    public static let clientId = "Xp6pAdwyJv9sQuoN"
    public static let clientSecret = "standard_a@api#"

    public static let appClientId = "Xp6vsxz_7IYVw2BB"
    public static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    public static let appClientVersion = "8.31.0.9726"
    public static let appPackageName = "com.xunlei.downloadprovider"

    public static let webAuthType = "webToken"
    public static let webClientId = "Xqp0kJXXXXXXXXXX"
    public static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// Android 端 10 层 captcha 盐（与 Android XunleiConstants.CAPTCHA_SALTS 逐字一致）
    public static let captchaSalts: [String] = [
        "9uJNVj/wLmdwKrJaVj/omlQ",
        "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
        "Eb+L7Ce+Ej48u",
        "jKY0",
        "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd",
        "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
        "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O",
        "5IiCoM9B1/788ntB",
        "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf",
        "+oK0AN"
    ]

    /// 下载与 API 专用客户端 UA（迅雷 CDN 要求 App UA，浏览器 UA 会触发 200 单流降级）
    public static let appUA =
        "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 " +
        "deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 " +
        "platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"

    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    // 兜底设备标识
    public static let fallbackDeviceId = "78a70629a2b17d0b4302317ffa94807a"
    public static let fallbackPeerId = "92df4c42e0926ff55f1c605ebe4c3754"
    public static let fallbackDeviceSign = "div101.78a70629a2b17d0b4302317ffa94807a31491e163e795b39e798ed33ae58858b"

    // 登录端点
    public static let captchaInitURL = "\(authBase)/v1/shield/captcha/init"
    public static let loginURL = "\(authBase)/xluser.core.login/v3/login"
    public static let sendSmsURL = "\(authBase)/xluser.core.login/v3/sendsms"
    public static let smsLoginURL = "\(authBase)/xluser.core.login/v3/smslogin"
    public static let tokenURL = "\(authBase)/v1/auth/signin/token"
    public static let refreshURL = "\(authBase)/v1/auth/token"

    // Pan 端点
    public static let aboutURL = "\(panBase)/drive/v1/about"
    public static let filesURL = "\(panBase)/drive/v1/files"
    public static let shareURL = "\(panBase)/drive/v1/share"
    public static let shareDetailURL = "\(panBase)/drive/v1/share/detail"
    public static let restoreURL = "\(panBase)/drive/v1/share/restore"
    public static let tasksURL = "\(panBase)/drive/v1/tasks"
    public static let trashURL = "\(panBase)/drive/v1/files:batchTrash"
    public static let deleteURL = "\(panBase)/drive/v1/files:batchDelete"
    public static let tempDirName = "YunX临时转存"
}
