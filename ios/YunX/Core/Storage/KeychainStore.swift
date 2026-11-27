//
//  KeychainStore.swift
//  YunX
//
//  基于 iOS 原生 Keychain 的敏感凭证安全存储（Cookie / JWT / Token）。
//

import Foundation
import Security

public final class KeychainStore: Sendable {
    public static let shared = KeychainStore()

    private let service: String

    public init(service: String = "com.yunx.ios.credentials") {
        self.service = service
    }

    @discardableResult
    public func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)

        var insertQuery = query
        insertQuery[kSecValueData as String] = data
        // 使用 AfterFirstUnlock 防止设备锁屏或改锁屏密码导致凭证丢失
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(insertQuery as CFDictionary, nil) == errSecSuccess
    }

    public func read(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
