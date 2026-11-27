//
//  Pan123Signer.swift
//  YunX
//
//  123 云盘请求签名（IEEE 802.3 CRC-32 + UTC+16h 替换表）与直链解包工具。
//

import Foundation

public enum Pan123Signer {
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    /// 标准 IEEE 802.3 CRC-32 小写十六进制（无前导零，与 Java Long.toHexString(crc.value) 完全一致）
    public static func crc32Hex(_ text: String) -> String {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in text.utf8 {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        crc ^= 0xFFFF_FFFF
        return String(crc, radix: 16)
    }

    /// 生成 (auth-key, auth-value) 签名对
    /// - Parameters:
    ///   - path: 含 `/b` 前缀、不含 host 和 query 的路径（如 `/b/api/share/download/info`）
    ///   - timestamp: Unix 秒级时间戳
    ///   - randomSeed: 随机整数（测试可注入固定值）
    public static func makeSign(
        path: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        randomSeed: Int? = nil
    ) -> (authKey: String, authValue: String) {
        let shifted = Date(timeIntervalSince1970: TimeInterval(timestamp + Pan123Constants.signOffsetSeconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted)
        let minute = String(
            format: "%04d%02d%02d%02d%02d",
            comps.year ?? 1970,
            comps.month ?? 1,
            comps.day ?? 1,
            comps.hour ?? 0,
            comps.minute ?? 0
        )

        var substituted = ""
        substituted.reserveCapacity(minute.count)
        for ch in minute {
            if let digit = ch.wholeNumberValue, digit >= 0, digit < Pan123Constants.signTable.count {
                substituted.append(Pan123Constants.signTable[digit])
            }
        }
        let authKey = crc32Hex(substituted)
        let random = randomSeed ?? Int.random(in: 0..<10_000_000)
        let payload = "\(timestamp)|\(random)|\(path)|\(Pan123Constants.signOS)|\(Pan123Constants.signVer)|\(authKey)"
        let authValue = "\(timestamp)-\(random)-\(crc32Hex(payload))"
        return (authKey, authValue)
    }

    /// 解码 123 下载链接包装（兼容整段 Base64 与 `download-v2?params=<base64>` 两种形态）
    public static func decodeDownloadURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            guard let data = decodeBase64Flexible(trimmed),
                  let str = String(data: data, encoding: .utf8),
                  str.lowercased().hasPrefix("http") else {
                return nil
            }
            return str
        }
        guard let range = trimmed.range(of: "params=") else { return nil }
        let after = String(trimmed[range.upperBound...])
        let paramValue = after.split(separator: "&", maxSplits: 1).first.map(String.init) ?? after
        guard let data = decodeBase64Flexible(paramValue),
              let str = String(data: data, encoding: .utf8),
              str.lowercased().hasPrefix("http") else {
            return nil
        }
        return str
    }

    public static func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 16_384 else { return false }
        return token.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    private static func decodeBase64Flexible(_ value: String) -> Data? {
        var norm = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = norm.count % 4
        if rem != 0 {
            norm.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: norm)
    }
}
