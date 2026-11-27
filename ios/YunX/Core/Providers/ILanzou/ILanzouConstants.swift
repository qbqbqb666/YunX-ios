//
//  ILanzouConstants.swift
//  YunX
//
//  蓝奏优享版（ilanzou）协议常量、AES-128-ECB 加密签名工具与结构化凭证载体。
//

import CommonCrypto
import Foundation

public struct ILanzouCredentialPayload: Codable, Sendable, Equatable {
    public var appToken: String
    public var uuid: String
    public var userId: String
    public var account: String

    public init(
        appToken: String,
        uuid: String = "",
        userId: String = "",
        account: String = ""
    ) {
        self.appToken = appToken
        self.uuid = uuid.isEmpty ? ILanzouConstants.newUuid() : uuid
        self.userId = userId
        self.account = account
    }

    public func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return appToken
        }
        return text
    }

    public static func decode(from raw: String) -> ILanzouCredentialPayload? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(ILanzouCredentialPayload.self, from: data),
           !parsed.appToken.isEmpty {
            return parsed
        }
        return ILanzouCredentialPayload(appToken: trimmed)
    }
}

public enum ILanzouConstants {
    public static let apiBase = "https://apis.ilanzou.com"
    public static let shareApiBase = "https://apix.ilanzou.com"
    public static let webSite = "https://www.ilanzou.com"

    public static let downloadReferer = "\(webSite)/"
    public static let downloadOrigin = webSite
    public static let webUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    public static let devType = "6"
    public static let devModel = "chrome"
    public static let shareDevModel = "Chrome"
    public static let devVersion = "125"
    public static let pageSize = 60

    public static let getUuidURL = "\(apiBase)/unproved/getUuid"
    public static let loginURL = "\(apiBase)/unproved/login"
    public static let accountMapURL = "\(apiBase)/proved/user/account/map"
    public static let fileRedirectURL = "\(apiBase)/unproved/file/redirect"
    public static let shareListURL = "\(shareApiBase)/unproved/share/list"
    public static let shareRedirectURL = "\(shareApiBase)/unproved/file/redirect"

    public static let rootFolderId = "0"
    public static let aesKey = "lanZouY-disk-app"
    public static let folderPrefix = "d:"
    public static let filePrefix = "f:"

    public static func newUuid() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<16).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    /// AES-128-ECB + PKCS7 填充 → 小写十六进制（对齐 Android ILanzouApi.aesHex）
    public static func aesHex(_ plain: String) -> String {
        let keyData = Data(aesKey.utf8)
        let inputData = Data(plain.utf8)
        let outLength = inputData.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outLength)
        var numBytesEncrypted = 0

        let status = keyData.withUnsafeBytes { keyPtr in
            inputData.withUnsafeBytes { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES128),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyPtr.baseAddress,
                    keyData.count,
                    nil,
                    dataPtr.baseAddress,
                    inputData.count,
                    &outBytes,
                    outLength,
                    &numBytesEncrypted
                )
            }
        }
        guard status == kCCSuccess else { return "" }
        return UploadSigning.hex(Data(outBytes.prefix(numBytesEncrypted)))
    }

    /// 蓝奏优享 query 参数编码：标准百分号编码后将 %3A 还原为字面冒号
    public static func encodeToken(_ value: String) -> String {
        UploadSigning.rfc3986Escape(value).replacingOccurrences(of: "%3A", with: ":")
    }

    public static func stripPrefix(_ fid: String) -> String {
        if fid.hasPrefix(folderPrefix) {
            return String(fid.dropFirst(folderPrefix.count))
        }
        if fid.hasPrefix(filePrefix) {
            return String(fid.dropFirst(filePrefix.count))
        }
        return fid
    }
}
