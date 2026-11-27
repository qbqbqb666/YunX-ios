//
//  Pan115Crypto.swift
//  YunX
//
//  115「电脑端」下载接口（proapi.115.com/app/chrome/downurl）私有加解密协议：
//  - 纯 Swift 零依赖 1024 位大整数模幂（modPow）+ PKCS#1 v1.5 填充 + 两段 XOR 变换；
//  - 与 Android Pan115Crypto.kt 逐字节对齐，突破网页端 50028 / 50029 大文件下载限制。
//

import Foundation
import Security

public enum Pan115CryptoError: LocalizedError, Sendable {
    case invalidKeyLength
    case invalidBase64
    case responseTooShort
    case missingRSASeparator

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: return "115 下载协议密钥长度必须为 16 字节"
        case .invalidBase64: return "115 下载响应 Base64 解码失败"
        case .responseTooShort: return "115 下载响应数据长度异常"
        case .missingRSASeparator: return "115 下载响应 RSA 填充格式错误"
        }
    }
}

public enum Pan115Crypto {
    private static let keyTable: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a,
        0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86,
        0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd,
        0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34,
        0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59,
        0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b,
        0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5
    ]

    private static let longKey: [UInt8] = [
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46
    ]

    private static let modulusHex =
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
        "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
        "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
        "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"

    private static let modulus = BigUInt(hex: modulusHex)
    private static let exponent: UInt64 = 0x10001
    private static let rsaEncodeBlock = 117
    private static let rsaBlock = 128

    /// 生成随机 16 字节请求密钥
    public static func newKey() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        if status != errSecSuccess {
            for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }

    /// 明文 JSON -> 请求体 data 参数（Base64）
    public static func encode(payload: String, key: [UInt8]) throws -> String {
        guard key.count == 16 else { throw Pan115CryptoError.invalidKeyLength }
        var body = Array(payload.utf8)
        symmetricEncode(&body, key: key)
        var plain = [UInt8]()
        plain.reserveCapacity(16 + body.count)
        plain.append(contentsOf: key)
        plain.append(contentsOf: body)
        let encrypted = rsaEncrypt(plain)
        return Data(encrypted).base64EncodedString()
    }

    /// 响应体 data 字段（Base64） -> 明文 JSON
    public static func decode(data base64Text: String, key: [UInt8]) throws -> String {
        guard key.count == 16 else { throw Pan115CryptoError.invalidKeyLength }
        guard let raw = Data(base64Encoded: base64Text, options: .ignoreUnknownCharacters) else {
            throw Pan115CryptoError.invalidBase64
        }
        let decrypted = try rsaDecrypt(Array(raw))
        guard decrypted.count > 16 else {
            throw Pan115CryptoError.responseTooShort
        }
        let salt = Array(decrypted[0..<16])
        var body = Array(decrypted[16...])
        symmetricDecode(&body, key: key, salt: salt)
        return String(decoding: body, as: UTF8.self)
    }

    // MARK: - 内部对称 XOR

    internal static func symmetricEncode(_ data: inout [UInt8], key: [UInt8]) {
        xorTransform(&data, key: deriveKey(seed: key, size: 4))
        data.reverse()
        xorTransform(&data, key: longKey)
    }

    internal static func symmetricDecode(_ data: inout [UInt8], key: [UInt8], salt: [UInt8]) {
        xorTransform(&data, key: deriveKey(seed: salt, size: 12))
        data.reverse()
        xorTransform(&data, key: deriveKey(seed: key, size: 4))
    }

    private static func deriveKey(seed: [UInt8], size: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            let left = Int(keyTable[size * i])
            let right = keyTable[size * (size - 1 - i)]
            let s = Int(seed[i % seed.count])
            out[i] = UInt8((s + left) & 0xff) ^ right
        }
        return out
    }

    private static func xorTransform(_ data: inout [UInt8], key: [UInt8]) {
        guard !key.isEmpty else { return }
        let offset = data.count % 4
        for i in 0..<offset {
            data[i] ^= key[i % key.count]
        }
        for i in offset..<data.count {
            data[i] ^= key[(i - offset) % key.count]
        }
    }

    // MARK: - 1024-bit RSA 分块

    private static func rsaEncrypt(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        while offset < input.count {
            let size = min(rsaEncodeBlock, input.count - offset)
            var block = [UInt8](repeating: 0xff, count: rsaBlock)
            block[0] = 0
            block[1] = 2
            let separator = rsaBlock - size - 1
            block[separator] = 0
            for i in 0..<size {
                block[separator + 1 + i] = input[offset + i]
            }
            let num = BigUInt(bigEndianBytes: block)
            let cipher = num.modPow(exponent: exponent, modulus: modulus)
            out.append(contentsOf: cipher.toBigEndianBytes(fixedLength: rsaBlock))
            offset += size
        }
        return out
    }

    private static func rsaDecrypt(_ input: [UInt8]) throws -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        while offset < input.count {
            let size = min(rsaBlock, input.count - offset)
            let block = Array(input[offset..<(offset + size)])
            let num = BigUInt(bigEndianBytes: block)
            let plain = num.modPow(exponent: exponent, modulus: modulus).toBigEndianBytes(fixedLength: rsaBlock)
            var start = -1
            for i in 2..<plain.count {
                if plain[i] == 0 {
                    start = i + 1
                    break
                }
            }
            guard start >= 1 && start < plain.count else {
                throw Pan115CryptoError.missingRSASeparator
            }
            out.append(contentsOf: plain[start...])
            offset += size
        }
        return out
    }
}

// MARK: - 零依赖轻量无符号大整数（专为 1024 位 RSA 模幂设计）

internal struct BigUInt: Sendable, Equatable {
    /// 小端 32-bit 肢数组（limbs[0] 为最低 32 位）
    var limbs: [UInt32]

    static let zero = BigUInt(limbs: [])
    static let one = BigUInt(limbs: [1])

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(hex: String) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = [UInt8]()
        let chars = Array(clean)
        var idx = 0
        if chars.count % 2 == 1 {
            if let v = UInt8(String(chars[0]), radix: 16) { bytes.append(v) }
            idx = 1
        }
        while idx + 1 < chars.count {
            let pair = String(chars[idx...(idx + 1)])
            if let v = UInt8(pair, radix: 16) { bytes.append(v) }
            idx += 2
        }
        self.init(bigEndianBytes: bytes)
    }

    init(bigEndianBytes bytes: [UInt8]) {
        var result: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var word: UInt32 = 0
            for j in start..<i {
                word = (word << 8) | UInt32(bytes[j])
            }
            result.append(word)
            i = start
        }
        self.limbs = result
        normalize()
    }

    mutating func normalize() {
        while limbs.last == 0 {
            limbs.removeLast()
        }
    }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func toBigEndianBytes(fixedLength: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: fixedLength)
        for byteIdx in 0..<fixedLength {
            let limbIdx = byteIdx / 4
            let shift = (byteIdx % 4) * 8
            let val: UInt8 = limbIdx < limbs.count ? UInt8((limbs[limbIdx] >> shift) & 0xff) : 0
            out[fixedLength - 1 - byteIdx] = val
        }
        return out
    }

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.limbs.count != b.limbs.count {
            return a.limbs.count < b.limbs.count ? -1 : 1
        }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) {
            if a.limbs[i] != b.limbs[i] {
                return a.limbs[i] < b.limbs[i] ? -1 : 1
            }
        }
        return 0
    }

    static func multiply(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        if a.limbs.isEmpty || b.limbs.isEmpty { return .zero }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let prod = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: prod)
                carry = prod >> 32
            }
            out[i + b.limbs.count] = UInt32(truncatingIfNeeded: UInt64(out[i + b.limbs.count]) + carry)
        }
        return BigUInt(limbs: out)
    }

    /// 要求 a >= b
    static func subtract(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let bv = i < b.limbs.count ? Int64(b.limbs[i]) : 0
            let diff = Int64(out[i]) - bv - borrow
            if diff < 0 {
                out[i] = UInt32(diff + (1 << 32))
                borrow = 1
            } else {
                out[i] = UInt32(diff)
                borrow = 0
            }
        }
        return BigUInt(limbs: out)
    }

    func shiftedLeft(by bits: Int) -> BigUInt {
        guard !limbs.isEmpty, bits > 0 else { return self }
        let wordShift = bits / 32
        let bitShift = bits % 32
        var out = [UInt32](repeating: 0, count: limbs.count + wordShift + (bitShift == 0 ? 0 : 1))
        if bitShift == 0 {
            for i in 0..<limbs.count {
                out[i + wordShift] = limbs[i]
            }
        } else {
            var carry: UInt32 = 0
            for i in 0..<limbs.count {
                let v = limbs[i]
                out[i + wordShift] = (v << bitShift) | carry
                carry = v >> (32 - bitShift)
            }
            out[limbs.count + wordShift] = carry
        }
        return BigUInt(limbs: out)
    }

    /// 移位相减取模（1024-bit 模幂仅调用 17 次，简单可靠且耗时不足 1ms）
    static func modulo(_ a: BigUInt, _ m: BigUInt) -> BigUInt {
        precondition(!m.limbs.isEmpty, "Modulo by zero")
        if compare(a, m) < 0 { return a }
        var rem = a
        let mBits = m.bitWidth
        while compare(rem, m) >= 0 {
            let shift = rem.bitWidth - mBits
            var candidate = m.shiftedLeft(by: shift)
            if compare(candidate, rem) > 0 {
                candidate = m.shiftedLeft(by: shift - 1)
            }
            rem = subtract(rem, candidate)
        }
        return rem
    }

    /// 快速模幂：self ^ exponent mod modulus
    func modPow(exponent: UInt64, modulus: BigUInt) -> BigUInt {
        var result = BigUInt.one
        var base = BigUInt.modulo(self, modulus)
        var exp = exponent
        while exp > 0 {
            if (exp & 1) == 1 {
                result = BigUInt.modulo(BigUInt.multiply(result, base), modulus)
            }
            exp >>= 1
            if exp > 0 {
                base = BigUInt.modulo(BigUInt.multiply(base, base), modulus)
            }
        }
        return result
    }
}
