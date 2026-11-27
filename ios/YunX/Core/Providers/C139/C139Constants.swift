//
//  C139Constants.swift
//  YunX
//
//  139 云盘（中国移动·和彩云）协议常量、Cookie 校验与账号/Authorization 提取工具。
//

import Foundation

public enum C139Constants {
    public static let loginURL = "https://yun.139.com/m/#/login"
    public static let cookieDomains = ["mail.10086.cn", "yun.139.com", "139.com"]

    public static let shareBase = "https://share-kd-njs.yun.139.com"
    public static let shareListURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6"
    public static let shareLinkURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/dlFromOutLinkV3"
    public static let shareGeneralURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/getOutLinkGeneral"
    public static let transferCreateURL = "\(shareBase)/yun-share/richlifeApp/devapp/IBatchOprTask/createOuterLinkBatchOprTask"

    // 个人网盘管理端点（明文 JSON + Authorization + mcloud-sign + APISIX 渠道头）
    public static let cloudBase = "https://personal-kd-njs.yun.139.com"
    public static let fileListURL = "\(cloudBase)/hcy/file/list"
    public static let fileCreateURL = "\(cloudBase)/hcy/file/create"
    public static let fileUploadURLURL = "\(cloudBase)/hcy/file/getUploadUrl"
    public static let fileUploadCompleteURL = "\(cloudBase)/hcy/file/complete"
    public static let fileUpdateURL = "\(cloudBase)/hcy/file/update"
    public static let batchMoveURL = "\(cloudBase)/hcy/file/batchMove"
    public static let taskGetURL = "\(cloudBase)/hcy/task/get"
    public static let batchTrashURL = "\(cloudBase)/hcy/recyclebin/batchTrash"
    public static let downloadURL = "\(cloudBase)/hcy/file/getDownloadUrl"
    public static let outlinkCreateURL = "https://yun.139.com/orchestration/personalCloud-rebuild/outlink/v1.0/getOutLink"
    public static let quotaDetailURL = "https://user-njs.yun.139.com/user/disk/quota/detail"

    public static let yunChannelSource = "10000034"
    public static let mcloudVersion = "7.17.9"
    public static let mcloudClient = "10701"
    public static let mcloudChannel = "1000101"
    public static let yunModuleType = "100"
    public static let m4cSrc = "10002"
    public static let m4cCaller = "PC"
    public static let xDeviceInfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||"
    public static let xClientInfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||dW5kZWZpbmVk||"

    /// 分享接口固定 AES-128-CBC 密钥（16 字节）
    public static let shareAESKey = "PVGDwmcvfs1uV3d1"

    /// 分享接口必需设备/渠道上下文头（缺失会触发 9530）
    public static let shareXDeviceInfo = "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||"
    public static let shareXHuaweiChannelSrc = "10245500"
    public static let shareXMMSource = "0002"

    public static let shareMobileUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"
    public static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public static let keepKeys: Set<String> = [
        "Os_SSo_Sid", "RMKEY", "UserData", "Login_UserNumber",
        "_139_index_isLoginType", "UUIDToken", "JSESSIONID",
        "areaCode8011", "provCode8011",
        "authorization", "auth_token", "token", "ud_id",
        "ORCHES-I-ACCOUNT-SIMPLIFY", "ORCHES-I-ACCOUNT-ENCRYPT", "nation_code",
        "platform", "skey", "a_k"
    ]

    public static func cookieValue(_ cookie: String, name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(name)=") {
                let val = String(trimmed.dropFirst(name.count + 1))
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie, !cookie.isEmpty else { return false }
        if cookieValue(cookie, name: "authorization") != nil { return true }
        return cookieValue(cookie, name: "Os_SSo_Sid") != nil && cookieValue(cookie, name: "RMKEY") != nil
    }

    public static func extractAuthorization(_ cookie: String?) -> String? {
        guard let cookie, !cookie.isEmpty else { return nil }
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Basic ") {
            return trimmed
        }
        return cookieValue(cookie, name: "authorization")
    }

    /// 从 authorization ("Basic base64(pc:账号:authToken)") 解码完整账号
    public static func accountFromAuthorization(_ authorization: String) -> String? {
        let b64 = authorization
            .replacingOccurrences(of: "Basic", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// 提取完整手机号（接口调用用）
    public static func extractAccountFull(_ cookie: String?) -> String? {
        guard let cookie, !cookie.isEmpty else { return nil }
        if let enc = cookieValue(cookie, name: "ORCHES-I-ACCOUNT-ENCRYPT"),
           let data = Data(base64Encoded: enc, options: .ignoreUnknownCharacters),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty {
            return decoded
        }
        if let auth = extractAuthorization(cookie),
           let acc = accountFromAuthorization(auth) {
            return acc
        }
        return cookieValue(cookie, name: "Login_UserNumber")
    }

    /// 提取展示昵称（脱敏手机号优先）
    public static func extractDisplayAccount(_ cookie: String?) -> String? {
        guard let cookie, !cookie.isEmpty else { return nil }
        if let simple = cookieValue(cookie, name: "ORCHES-I-ACCOUNT-SIMPLIFY") {
            return simple
        }
        return extractAccountFull(cookie)
    }
}
