//
//  AuthCrypto.swift
//  YunX
//
//  与 Android/PC 端 100% 字节级互通的认证备份加密实现：
//  - 密钥派生：PBKDF2-HMAC-SHA256（16 字节随机盐；V2=210,000 次迭代，兼容 V1=10,000 次）
//  - 认证加密：AES-256-GCM（12 字节 IV，16 字节 Tag 附于密文尾部，与 Java Cipher AES/GCM/NoPadding 一致）
//  - 载荷格式：Base64("YUNX_AUTH_V2" + salt(16) + iv(12) + ciphertext + tag(16))
//

import CommonCrypto
import CryptoKit
import Foundation

public enum AuthCryptoError: LocalizedError, Sendable {
    case passwordTooShort
    case invalidBase64
    case notEncryptedFormat
    case corruptedPayload
    case keyDerivationFailed
    case decryptFailed

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort: return "备份口令至少需要 8 位字符"
        case .invalidBase64: return "备份内容格式无效"
        case .notEncryptedFormat: return "不是有效的云析加密备份文件"
        case .corruptedPayload: return "备份文件已损坏或不完整"
        case .keyDerivationFailed: return "密钥派生失败"
        case .decryptFailed: return "口令错误或备份文件已被篡改"
        }
    }
}

public enum AuthCrypto {
    private static let magicV1 = Data("YUNX_AUTH_V1".utf8)
    private static let magicV2 = Data("YUNX_AUTH_V2".utf8)
    private static let iterationsV1: UInt32 = 10_000
    private static let iterationsV2: UInt32 = 210_000
    private static let keyLength = 32 // 256-bit
    private static let saltSize = 16
    private static let ivSize = 12
    private static let tagSize = 16

    public static func encrypt(plaintext: String, password: String) throws -> String {
        guard password.count >= 8 else { throw AuthCryptoError.passwordTooShort }
        let salt = randomBytes(count: saltSize)
        let iv = randomBytes(count: ivSize)
        let keyData = try deriveKey(password: password, salt: salt, iterations: iterationsV2)
        let key = SymmetricKey(data: keyData)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)

        // 与 Java AES/GCM/NoPadding 对齐：ciphertext || tag(16B)
        var payload = Data()
        payload.append(magicV2)
        payload.append(salt)
        payload.append(iv)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)
        return payload.base64EncodedString()
    }

    public static func decrypt(base64Data: String, password: String) throws -> String {
        let cleaned = base64Data
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let payload = Data(base64Encoded: cleaned) else {
            throw AuthCryptoError.invalidBase64
        }

        let magic: Data
        let iterations: UInt32
        if payload.starts(with: magicV2) {
            magic = magicV2
            iterations = iterationsV2
        } else if payload.starts(with: magicV1) {
            magic = magicV1
            iterations = iterationsV1
        } else {
            throw AuthCryptoError.notEncryptedFormat
        }

        let headerSize = magic.count + saltSize + ivSize
        guard payload.count >= headerSize + tagSize else {
            throw AuthCryptoError.corruptedPayload
        }

        let saltStart = magic.count
        let ivStart = saltStart + saltSize
        let bodyStart = ivStart + ivSize
        let tagStart = payload.count - tagSize

        let salt = payload.subdata(in: saltStart..<ivStart)
        let iv = payload.subdata(in: ivStart..<bodyStart)
        let ciphertext = payload.subdata(in: bodyStart..<tagStart)
        let tag = payload.subdata(in: tagStart..<payload.count)

        let keyData = try deriveKey(password: password, salt: salt, iterations: iterations)
        let key = SymmetricKey(data: keyData)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        do {
            let opened = try AES.GCM.open(sealedBox, using: key)
            guard let text = String(data: opened, encoding: .utf8) else {
                throw AuthCryptoError.corruptedPayload
            }
            return text
        } catch {
            throw AuthCryptoError.decryptFailed
        }
    }

    public static func isEncrypted(_ content: String) -> Bool {
        let cleaned = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let payload = Data(base64Encoded: cleaned) else { return false }
        return payload.starts(with: magicV2) || payload.starts(with: magicV1)
    }

    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> Data {
        let passwordData = Data(password.utf8)
        var derived = Data(repeating: 0, count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw AuthCryptoError.keyDerivationFailed
        }
        return derived
    }

    private static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        return data
    }
}
