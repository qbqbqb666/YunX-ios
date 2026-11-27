//
//  Pan115Constants.swift
//  YunX
//
//  115 网盘协议常量、动态客户端版本号管理、Cookie 工具与分享 Token 编解码。
//

import Foundation

public enum Pan115Constants {
    public static let apiBase = "https://webapi.115.com"
    public static let webLoginURL = "https://115.com/"
    public static let shareHost = "https://115cdn.com"
    public static let referer = "https://115.com/"
    public static let downloadReferer = "https://115.com/"

    // 接口端点
    public static let userInfoURL = "\(apiBase)/user/info?ct=json"
    public static let indexInfoURL = "\(apiBase)/files/index_info?count_space_nums=1"
    public static let filesURL = "\(apiBase)/files"
    public static let fileAddURL = "\(apiBase)/files/add"
    public static let fileRenameURL = "\(apiBase)/files/batch_rename"
    public static let fileMoveURL = "\(apiBase)/files/move"
    public static let moveProgressURL = "\(apiBase)/files/move_progress"
    public static let fileDeleteURL = "\(apiBase)/rb/delete"
    public static let fileDownloadURL = "\(apiBase)/files/download"
    public static let uploadInitURL = "https://uplb.115.com/3.0/sampleinitupload.php"
    public static let uploadMaxSize: Int64 = 5 * 1024 * 1024 * 1024
    public static let appDownloadURL = "https://proapi.115.com/app/chrome/downurl"
    public static let shareSnapURL = "\(apiBase)/share/snap"
    public static let shareDownloadURL = "\(apiBase)/share/downurl"
    public static let shareReceiveURL = "\(apiBase)/share/receive"
    public static let allowProtocolURL = "\(apiBase)/user/allow_protocol"
    public static let shareSendURL = "\(apiBase)/share/send"
    public static let shareUpdateURL = "\(apiBase)/share/updateshare"
    public static let appVersionURL = "https://appversion.115.com/1/web/1.0/api/chrome"

    // 临时转存目录约定
    public static let aidPersonal = "1"
    public static let rootCid = "0"
    public static let pageLimit = 100
    public static let sharePageLimit = 100
    public static let tempDirName = "YunX临时转存"
    public static let tempSubdirPrefix = "tr_"

    // 请求头
    public static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    public static let xRequestedWith = "XMLHttpRequest"
    public static let clientUAVersionFallback = "36.0.1"

    public static let cookieDomains = ["115.com", "webapi.115.com"]
    public static let cookieKeepKeys: Set<String> = [
        "UID", "CID", "SEID", "KID", "PHPSESSID", "GST", "USERSESSIONID"
    ]

    // 错误码
    public static let errnoLoginTimeout = 990001
    public static let errnoNeedCode = 4100012
    public static let errnoWrongCode = 4100008
    public static let errnoShareGone = 4100026
    public static let errnoWebSizeLimit = 50028
    public static let errnoClientTooOld = 50029

    // 线程安全动态客户端 UA（由 appversion.115.com 刷新）
    private static let uaLock = NSLock()
    private nonisolated(unsafe) static var _clientUA: String = "Mozilla/5.0 115Browser/\(clientUAVersionFallback)"

    public static var clientUA: String {
        uaLock.lock()
        defer { uaLock.unlock() }
        return _clientUA
    }

    public static func applyClientVersion(_ version: String?) {
        guard let raw = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let first = raw.first, first.isNumber,
              raw.count <= 16,
              raw.allSatisfy({ $0.isNumber || $0 == "." }) else {
            return
        }
        uaLock.lock()
        _clientUA = "Mozilla/5.0 115Browser/\(raw)"
        uaLock.unlock()
    }

    public static func shareReferer(shareCode: String, receiveCode: String) -> String {
        if receiveCode.isEmpty {
            return "\(shareHost)/s/\(shareCode)"
        }
        return "\(shareHost)/s/\(shareCode)?password=\(receiveCode)&"
    }

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

    public static func hasLoginCookie(_ cookie: String) -> Bool {
        cookieValue(cookie, name: "UID") != nil
    }

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie, !cookie.isEmpty else { return false }
        return cookieValue(cookie, name: "UID") != nil && cookieValue(cookie, name: "SEID") != nil
    }

    public static func extractUserId(_ cookie: String) -> String? {
        guard let uid = cookieValue(cookie, name: "UID") else { return nil }
        let prefix = uid.split(separator: "_", maxSplits: 1).first.map(String.init) ?? uid
        return prefix.isEmpty ? nil : prefix
    }

    public static func mergeCookies(_ parts: String...) -> String {
        parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "; ")
    }

    public static func encodeShareToken(receiveCode: String, userId: String) -> String {
        "\(receiveCode)|\(userId)"
    }

    public static func decodeShareToken(_ token: String) -> (receiveCode: String, userId: String) {
        guard let idx = token.firstIndex(of: "|") else {
            return (token, "")
        }
        return (String(token[..<idx]), String(token[token.index(after: idx)...]))
    }
}
