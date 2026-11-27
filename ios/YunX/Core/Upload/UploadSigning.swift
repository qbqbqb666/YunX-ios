//
//  UploadSigning.swift
//  YunX
//
//  个人云盘上传纯算法模块：十六进制、SHA-256、MD5、HMAC-SHA1/SHA256、
//  阿里云 OSS V1 签名、AWS S3 V4 签名、迅雷 gcid 与分片合并 XML 工具。
//

import CommonCrypto
import CryptoKit
import Foundation

public enum UploadSigning {
    public static func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    public static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    public static func md5Data(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    public static func hmacSHA1(key: Data, data: Data) -> Data {
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyPtr.baseAddress,
                    key.count,
                    dataPtr.baseAddress,
                    data.count,
                    &mac
                )
            }
        }
        return Data(mac)
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: symKey)
        return Data(code)
    }

    /// 阿里云 OSS V1 Authorization 头（光鸭 / OSS 临时凭据直传）
    public static func ossV1Authorization(
        accessKey: String,
        secretKey: String,
        method: String,
        contentType: String,
        date: String,
        canonicalResource: String,
        securityToken: String = ""
    ) -> String {
        let tokenPart = securityToken.isEmpty ? "" : "x-oss-security-token:\(securityToken)\n"
        let toSign = "\(method)\n\n\(contentType)\n\(date)\n\(tokenPart)\(canonicalResource)"
        let sig = hmacSHA1(key: Data(secretKey.utf8), data: Data(toSign.utf8)).base64EncodedString()
        return "OSS \(accessKey):\(sig)"
    }

    /// AWS S3 V4 Authorization 签名计算（123 S3 直传 / 迅雷）
    public static func s3V4Authorization(
        accessKey: String,
        secretKey: String,
        region: String,
        method: String,
        canonicalPath: String,
        canonicalQuery: String,
        host: String,
        amzDate: String,
        contentSha256: String,
        securityToken: String = ""
    ) -> String {
        let dateStamp = String(amzDate.prefix(8))
        var signedMap: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", contentSha256),
            ("x-amz-date", amzDate)
        ]
        if !securityToken.isEmpty {
            signedMap.append(("x-amz-security-token", securityToken))
        }
        signedMap.sort { $0.0 < $1.0 }

        let headerNames = signedMap.map(\.0).joined(separator: ";")
        let canonicalHeaders = signedMap.map { "\($0.0):\($0.1)\n" }.joined()
        let canonicalRequest = "\(method)\n\(canonicalPath)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(headerNames)\n\(contentSha256)"

        let scope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"

        var key = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        key = hmacSHA256(key: key, data: Data(region.utf8))
        key = hmacSHA256(key: key, data: Data("s3".utf8))
        key = hmacSHA256(key: key, data: Data("aws4_request".utf8))
        let signature = hex(hmacSHA256(key: key, data: Data(stringToSign.utf8)))

        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(headerNames), Signature=\(signature)"
    }

    /// 迅雷 gcid：拼接各分块 SHA-1 原始字节后再做一次 SHA-1，输出大写十六进制
    public static func gcid(blockDigests: [Data]) -> String {
        var concat = Data()
        for d in blockDigests {
            concat.append(d)
        }
        let finalDigest = Data(Insecure.SHA1.hash(data: concat))
        return hex(finalDigest).uppercased()
    }

    // MARK: - XML / RFC 编码工具

    public static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    public static func xmlError(_ body: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<(?:[\\w-]+:)?Error(?:\\s|>)") else {
            return body.contains("<Error>")
        }
        let range = NSRange(body.startIndex..., in: body)
        return regex.firstMatch(in: body, range: range) != nil
    }

    public static func xmlValue(_ body: String, tag: String) -> String {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(pattern: "<\(escapedTag)>([\\s\\S]*?)</\(escapedTag)>") else {
            return ""
        }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              match.numberOfRanges > 1,
              let innerRange = Range(match.range(at: 1), in: body) else {
            return ""
        }
        return String(body[innerRange])
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func completeXml(etags: [String]) -> String {
        var out = "<CompleteMultipartUpload>"
        for (idx, etag) in etags.enumerated() {
            out += "<Part><PartNumber>\(idx + 1)</PartNumber><ETag>\(xmlEscape(etag))</ETag></Part>"
        }
        out += "</CompleteMultipartUpload>"
        return out
    }

    /// RFC 1123 GMT 日期（OSS V1 Date 头）
    public static func httpDate(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(abbreviation: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return fmt.string(from: now)
    }

    /// AWS S3 V4 ISO 时间戳（yyyyMMdd'T'HHmmss'Z'）
    public static func isoStamp(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(abbreviation: "GMT")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return fmt.string(from: now)
    }

    /// RFC 3986 路径段 / 查询值百分号编码（保留 A-Z a-z 0-9 - . _ ~）
    public static func rfc3986Escape(_ raw: String) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out = [UInt8]()
        for b in raw.utf8 {
            let safe = (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A)
                || (b >= 0x30 && b <= 0x39)
                || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
            if safe {
                out.append(b)
            } else {
                out.append(0x25) // '%'
                out.append(digits[Int(b >> 4)])
                out.append(digits[Int(b & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
