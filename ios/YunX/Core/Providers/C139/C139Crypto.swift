//
//  C139Crypto.swift
//  YunX
//
//  139 云盘（和彩云）协议加解密与签名：
//  - mcloud-sign 签名（encodeURIComponent → ASCII 升序 → Base64 → 双 MD5 拼接再 MD5 大写）；
//  - 分享接口 AES-128-CBC (PKCS7) IV 前置加解密 + gzip 自动解压（对齐 Android C139Api.kt）。
//

import Foundation
import CommonCrypto
import CryptoKit
import Security
import zlib

public enum C139CryptoError: LocalizedError, Sendable {
    case invalidBase64
    case aesFailed(Int32)
    case gzipFailed

    public var errorDescription: String? {
        switch self {
        case .invalidBase64: return "139 加密响应 Base64 解码失败"
        case .aesFailed(let status): return "139 AES 加解密失败（状态码 \(status)）"
        case .gzipFailed: return "139 响应 GZIP 解压失败"
        }
    }
}

public enum C139Crypto {
    /// JavaScript 等价 encodeURIComponent（保留 A-Z a-z 0-9 - _ . ! ~ * ' ( )）
    public static func encodeURIComponent(_ input: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }

    /// 计算 mcloud-sign 签名值
    public static func calSign(bodyJson: String, ts: String, rand: String) -> String {
        let encoded = encodeURIComponent(bodyJson)
        let sorted = String(encoded.sorted { $0.utf16.first ?? 0 < $1.utf16.first ?? 0 })
        let b64 = Data(sorted.utf8).base64EncodedString()
        let combined = md5Hex(b64) + md5Hex("\(ts):\(rand)")
        return md5Hex(combined).uppercased()
    }

    /// 生成完整 mcloud-sign 请求头：`<YYYY-MM-DD HH:mm:ss>,<rand16>,<SIGN>`
    public static func signHeader(bodyJson: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = formatter.string(from: date)

        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let rand = String((0..<16).map { _ in pool[Int.random(in: 0..<pool.count)] })
        return "\(ts),\(rand),\(calSign(bodyJson: bodyJson, ts: ts, rand: rand))"
    }

    /// 明文 JSON -> Base64(16字节随机IV || AES-128-CBC-PKCS7(明文))
    public static func encryptBody(_ plaintext: String, keyString: String = C139Constants.shareAESKey) throws -> String {
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        if SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) != errSecSuccess {
            for i in 0..<iv.count { iv[i] = UInt8.random(in: 0...255) }
        }
        let keyBytes = Array(keyString.utf8)
        let plainBytes = Array(plaintext.utf8)
        let outCap = plainBytes.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCap)
        var outLen = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes, keyBytes.count,
            iv,
            plainBytes, plainBytes.count,
            &outBytes, outCap,
            &outLen
        )
        guard status == kCCSuccess else {
            throw C139CryptoError.aesFailed(status)
        }
        var combined = Data(iv)
        combined.append(contentsOf: outBytes.prefix(outLen))
        return combined.base64EncodedString()
    }

    /// Base64(IV || 密文) -> 明文 JSON（自动识别 0x1f 0x8b GZIP 并解压）
    public static func decryptBody(_ base64Text: String, keyString: String = C139Constants.shareAESKey) throws -> String {
        let trimmed = base64Text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              raw.count > kCCBlockSizeAES128 else {
            throw C139CryptoError.invalidBase64
        }
        let iv = Array(raw.prefix(kCCBlockSizeAES128))
        let ct = Array(raw.dropFirst(kCCBlockSizeAES128))
        let keyBytes = Array(keyString.utf8)
        let outCap = ct.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: outCap)
        var outLen = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes, keyBytes.count,
            iv,
            ct, ct.count,
            &outBytes, outCap,
            &outLen
        )
        guard status == kCCSuccess else {
            throw C139CryptoError.aesFailed(status)
        }

        var result = Data(outBytes.prefix(outLen))
        if result.count > 2 && result[0] == 0x1f && result[1] == 0x8b {
            result = try gunzip(result)
        }
        return String(data: result, encoding: .utf8) ?? ""
    }

    /// 使用系统 zlib 解压 GZIP 字节流
    public static func gunzip(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var stream = z_stream()
        var status: Int32 = Z_OK
        let initStatus = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw C139CryptoError.gzipFailed }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { rawPtr in
            guard let basePtr = rawPtr.bindMemory(to: Bytef.self).baseAddress else {
                throw C139CryptoError.gzipFailed
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: basePtr)
            stream.avail_in = uInt(data.count)

            repeat {
                let produced: Int = buffer.withUnsafeMutableBytes { outRaw in
                    let outPtr = outRaw.bindMemory(to: Bytef.self).baseAddress!
                    stream.next_out = outPtr
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status != Z_OK && status != Z_STREAM_END {
                    throw C139CryptoError.gzipFailed
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    private static func md5Hex(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
