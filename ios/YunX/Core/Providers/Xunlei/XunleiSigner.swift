//
//  XunleiSigner.swift
//  YunX
//
//  迅雷设备指纹持久化、10 层 MD5 captcha_sign 签名算法与 JWT 载荷解码工具。
//

import Foundation
import CryptoKit

public enum XunleiSigner {
    private static let keyDeviceId = "yunx.xunlei.fp.deviceId"
    private static let keyPeerId = "yunx.xunlei.fp.peerId"
    private static let keyDeviceSign = "yunx.xunlei.fp.deviceSign"

    private static let appId = "40"
    private static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"
    private static let lock = NSLock()

    public static func deviceId() -> String {
        ensureFingerprint().deviceId
    }

    public static func peerId() -> String {
        ensureFingerprint().peerId
    }

    public static func deviceSign() -> String {
        ensureFingerprint().deviceSign
    }

    /// 计算 10 层加盐 MD5 的 captcha_sign（前缀固定 "1."）
    public static func buildCaptchaSign(deviceId: String, timestampMs: String) -> String {
        var acc = XunleiConstants.appClientId +
            XunleiConstants.appClientVersion +
            XunleiConstants.appPackageName +
            deviceId +
            timestampMs
        for salt in XunleiConstants.captchaSalts {
            acc = md5Hex(acc + salt)
        }
        return "1.\(acc)"
    }

    /// 计算 devicesign：div101.<deviceId><md5(sha1(deviceId + package + appid + appkey))>
    public static func buildDeviceSign(deviceId: String) -> String {
        let base = deviceId + XunleiConstants.appPackageName + appId + appKey
        let sha1 = sha1Hex(base)
        let md5 = md5Hex(sha1)
        return "div101.\(deviceId)\(md5)"
    }

    /// 解析 JWT sub（用户 ID）
    public static func jwtSub(_ token: String) -> String {
        (jwtPayload(token)?["sub"] as? String) ?? ""
    }

    /// 解析 JWT exp（Unix 秒）
    public static func jwtExp(_ token: String) -> Int64 {
        if let n = jwtPayload(token)?["exp"] as? NSNumber {
            return n.int64Value
        }
        return 0
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64 += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func ensureFingerprint() -> (deviceId: String, peerId: String, deviceSign: String) {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        if let savedId = defaults.string(forKey: keyDeviceId), !savedId.isEmpty {
            let peer = defaults.string(forKey: keyPeerId) ?? XunleiConstants.fallbackPeerId
            let sign = defaults.string(forKey: keyDeviceSign) ?? buildDeviceSign(deviceId: savedId)
            return (savedId, peer, sign)
        }
        let newId = randomHex(32)
        let newPeer = randomHex(32)
        let newSign = buildDeviceSign(deviceId: newId)
        defaults.set(newId, forKey: keyDeviceId)
        defaults.set(newPeer, forKey: keyPeerId)
        defaults.set(newSign, forKey: keyDeviceSign)
        return (newId, newPeer, newSign)
    }

    private static func randomHex(_ count: Int) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<count).map { _ in chars[Int.random(in: 0..<16)] })
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
