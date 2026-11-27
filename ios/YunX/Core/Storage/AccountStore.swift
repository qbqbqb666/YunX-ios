//
//  AccountStore.swift
//  YunX
//
//  多平台账号状态管理：元数据落地 UserDefaults JSON，敏感 Cookie/JWT 落 iOS Keychain。
//

import Foundation
import Observation

@MainActor
@Observable
public final class AccountStore {
    public private(set) var accounts: [SharePlatform: AccountRecord] = [:]

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let metadataKey = "yunx.accounts.metadata.v1"

    public init(keychain: KeychainStore = .shared, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        loadMetadata()
    }

    public func isLoggedIn(_ platform: SharePlatform) -> Bool {
        guard let cred = credential(for: platform) else { return false }
        return !cred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func credential(for platform: SharePlatform) -> String? {
        keychain.read(forKey: credentialKey(for: platform))
    }

    public func record(for platform: SharePlatform) -> AccountRecord? {
        accounts[platform]
    }

    public func saveAccount(
        platform: SharePlatform,
        credential: String,
        nickname: String = "",
        accountIdentifier: String = "",
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keychain.save(trimmed, forKey: credentialKey(for: platform))
        accounts[platform] = AccountRecord(
            platform: platform,
            nickname: nickname.isEmpty ? (accounts[platform]?.nickname ?? "") : nickname,
            accountIdentifier: accountIdentifier.isEmpty ? (accounts[platform]?.accountIdentifier ?? "") : accountIdentifier,
            updatedAt: updatedAt
        )
        persistMetadata()
    }

    /// 仅当传入的 requestCredential 与当前存储凭证一致时才回写续期后的 Cookie，防止并发覆盖
    public func updateCredentialIfMatching(platform: SharePlatform, merged: String, matching requestCredential: String) {
        guard let current = credential(for: platform), current == requestCredential else { return }
        keychain.save(merged, forKey: credentialKey(for: platform))
        if var existing = accounts[platform] {
            existing.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
            accounts[platform] = existing
            persistMetadata()
        }
    }

    public func removeAccount(for platform: SharePlatform) {
        keychain.delete(forKey: credentialKey(for: platform))
        accounts.removeValue(forKey: platform)
        persistMetadata()
    }

    private func credentialKey(for platform: SharePlatform) -> String {
        "credential.\(platform.rawValue)"
    }

    private func loadMetadata() {
        guard let data = defaults.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([AccountRecord].self, from: data) else {
            return
        }
        var map: [SharePlatform: AccountRecord] = [:]
        for item in decoded where isLoggedIn(item.platform) {
            map[item.platform] = item
        }
        self.accounts = map
    }

    private func persistMetadata() {
        let list = Array(accounts.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: metadataKey)
        }
    }
}
