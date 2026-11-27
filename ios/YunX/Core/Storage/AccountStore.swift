//
//  AccountStore.swift
//  YunX
//
//  多平台多账号状态管理：
//  - 同平台支持保存多个账号、备注命名与一键切换当前活跃主账号；
//  - 元数据落地 UserDefaults JSON（无缝兼容旧单账号 v1 数据），敏感凭证按槽位隔离落 iOS Keychain；
//  - 凭证续期按原凭证精确匹配槽位回写，绝不跨账号串号。
//

import Foundation
import Observation

@MainActor
@Observable
public final class AccountStore {
    /// 每个平台当前活跃（主）账号映射（保持与既有调用方 100% 兼容）
    public private(set) var accounts: [SharePlatform: AccountRecord] = [:]
    /// 全平台全部账号列表（支持同平台多账号）
    public private(set) var allAccounts: [AccountRecord] = []
    /// 变更版本号（切号/增删/改备注递增，供云盘页监听并刷新）
    public private(set) var revision: Int = 0

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

    /// 获取指定平台当前活跃（主）账号凭证
    public func credential(for platform: SharePlatform) -> String? {
        if let active = accounts[platform] {
            return credential(forAccountId: active.id, platform: platform)
        }
        return keychain.read(forKey: legacyCredentialKey(for: platform))
    }

    /// 获取指定账号槽位的凭证
    public func credential(forAccountId accountId: String, platform: SharePlatform) -> String? {
        keychain.read(forKey: credentialKey(accountId: accountId, platform: platform))
    }

    /// 获取指定平台当前活跃（主）账号元数据
    public func record(for platform: SharePlatform) -> AccountRecord? {
        accounts[platform]
    }

    /// 获取指定平台的全部已保存账号（主账号排最前，其余按更新时间降序）
    public func accounts(for platform: SharePlatform) -> [AccountRecord] {
        allAccounts
            .filter { $0.platform == platform }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    /// 保存账号凭证：
    /// - 该平台尚无账号：使用平台名作为主键并设为活跃主账号（与旧单账号槽位一致）；
    /// - `asNewAccount == false`：覆盖当前活跃主账号并保留其备注；
    /// - `asNewAccount == true`：创建独立新槽位保存，若 `activateNew == true` 同时切换为活跃主账号。
    @discardableResult
    public func saveAccount(
        platform: SharePlatform,
        credential: String,
        nickname: String = "",
        accountIdentifier: String = "",
        remark: String = "",
        asNewAccount: Bool = false,
        activateNew: Bool = true,
        preferredId: String? = nil,
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> AccountRecord? {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let existingForPlatform = accounts(for: platform)
        let targetId: String
        let inheritedRemark: String
        let inheritedNick: String
        let inheritedIdentifier: String
        let makePrimary: Bool

        if let preferredId, !preferredId.isEmpty {
            targetId = preferredId
            let existing = existingForPlatform.first(where: { $0.id == preferredId })
            inheritedRemark = existing?.remark ?? ""
            inheritedNick = existing?.nickname ?? ""
            inheritedIdentifier = existing?.accountIdentifier ?? ""
            makePrimary = existingForPlatform.isEmpty || activateNew || (existing?.isPrimary == true)
        } else if existingForPlatform.isEmpty {
            targetId = platform.rawValue
            inheritedRemark = ""
            inheritedNick = ""
            inheritedIdentifier = ""
            makePrimary = true
        } else if asNewAccount {
            targetId = Self.makeNewSlotId(for: platform, existingIds: Set(allAccounts.map(\.id)))
            inheritedRemark = ""
            inheritedNick = ""
            inheritedIdentifier = ""
            makePrimary = activateNew
        } else {
            let currentPrimary = existingForPlatform.first(where: \.isPrimary) ?? existingForPlatform[0]
            targetId = currentPrimary.id
            inheritedRemark = currentPrimary.remark
            inheritedNick = currentPrimary.nickname
            inheritedIdentifier = currentPrimary.accountIdentifier
            makePrimary = true
        }

        keychain.save(trimmed, forKey: credentialKey(accountId: targetId, platform: platform))

        if makePrimary {
            for idx in allAccounts.indices where allAccounts[idx].platform == platform {
                allAccounts[idx].isPrimary = false
            }
        }

        let record = AccountRecord(
            id: targetId,
            platform: platform,
            nickname: nickname.isEmpty ? inheritedNick : nickname,
            remark: remark.isEmpty ? inheritedRemark : remark,
            accountIdentifier: accountIdentifier.isEmpty ? inheritedIdentifier : accountIdentifier,
            isPrimary: makePrimary,
            updatedAt: updatedAt
        )

        if let existingIndex = allAccounts.firstIndex(where: { $0.id == targetId }) {
            allAccounts[existingIndex] = record
        } else {
            allAccounts.append(record)
        }

        ensurePrimaryInvariant(for: platform)
        rebuildPrimaryMapAndPersist()
        return record
    }

    /// 一键切换指定平台的活跃主账号
    public func setPrimary(accountId: String, for platform: SharePlatform) {
        guard allAccounts.contains(where: { $0.id == accountId && $0.platform == platform }) else { return }
        for idx in allAccounts.indices where allAccounts[idx].platform == platform {
            allAccounts[idx].isPrimary = (allAccounts[idx].id == accountId)
        }
        rebuildPrimaryMapAndPersist()
    }

    /// 修改账号自定义备注
    public func updateRemark(accountId: String, remark: String) {
        guard let idx = allAccounts.firstIndex(where: { $0.id == accountId }) else { return }
        allAccounts[idx].remark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuildPrimaryMapAndPersist()
    }

    /// 仅当某账号槽位当前凭证与 requestCredential 一致时才回写续期后的凭证，防止多账号串号
    public func updateCredentialIfMatching(platform: SharePlatform, merged: String, matching requestCredential: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for idx in allAccounts.indices where allAccounts[idx].platform == platform {
            let slotId = allAccounts[idx].id
            let key = credentialKey(accountId: slotId, platform: platform)
            if keychain.read(forKey: key) == requestCredential {
                keychain.save(merged, forKey: key)
                allAccounts[idx].updatedAt = now
                rebuildPrimaryMapAndPersist()
                return
            }
        }
    }

    /// 删除指定槽位的单个账号（若删除的是当前主账号，自动将同平台下一个可用账号提升为主账号）
    public func removeAccount(id accountId: String) {
        guard let idx = allAccounts.firstIndex(where: { $0.id == accountId }) else { return }
        let removed = allAccounts.remove(at: idx)
        keychain.delete(forKey: credentialKey(accountId: removed.id, platform: removed.platform))
        ensurePrimaryInvariant(for: removed.platform)
        rebuildPrimaryMapAndPersist()
    }

    /// 退出指定平台当前活跃账号（保持兼容既有单账号退出语义）
    public func removeAccount(for platform: SharePlatform) {
        if let active = accounts[platform] {
            removeAccount(id: active.id)
        } else {
            keychain.delete(forKey: legacyCredentialKey(for: platform))
            rebuildPrimaryMapAndPersist()
        }
    }

    /// 清空指定平台下的全部账号
    public func removeAllAccounts(for platform: SharePlatform) {
        let targets = allAccounts.filter { $0.platform == platform }
        for item in targets {
            keychain.delete(forKey: credentialKey(accountId: item.id, platform: item.platform))
        }
        keychain.delete(forKey: legacyCredentialKey(for: platform))
        allAccounts.removeAll { $0.platform == platform }
        rebuildPrimaryMapAndPersist()
    }

    // MARK: - 内部存储与不变量维护

    private func legacyCredentialKey(for platform: SharePlatform) -> String {
        "credential.\(platform.rawValue)"
    }

    private func credentialKey(accountId: String, platform: SharePlatform) -> String {
        if accountId == platform.rawValue {
            return legacyCredentialKey(for: platform)
        }
        return "credential.slot.\(accountId)"
    }

    private static func makeNewSlotId(for platform: SharePlatform, existingIds: Set<String>) -> String {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        var candidate = "\(platform.rawValue)-\(ts)"
        while existingIds.contains(candidate) {
            candidate = "\(platform.rawValue)-\(ts)-\(Int.random(in: 100...999))"
        }
        return candidate
    }

    private func ensurePrimaryInvariant(for platform: SharePlatform) {
        let indices = allAccounts.indices.filter { allAccounts[$0].platform == platform }
        guard !indices.isEmpty else { return }
        let primaryIndices = indices.filter { allAccounts[$0].isPrimary }
        if primaryIndices.count == 1 { return }
        for idx in indices {
            allAccounts[idx].isPrimary = false
        }
        let chosen = primaryIndices.first ?? indices.max(by: { allAccounts[$0].updatedAt < allAccounts[$1].updatedAt }) ?? indices[0]
        allAccounts[chosen].isPrimary = true
    }

    private func loadMetadata() {
        guard let data = defaults.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([AccountRecord].self, from: data) else {
            return
        }
        var valid: [AccountRecord] = []
        for item in decoded {
            if let cred = credential(forAccountId: item.id, platform: item.platform),
               !cred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                valid.append(item)
            }
        }
        self.allAccounts = valid
        for platform in SharePlatform.allCases {
            ensurePrimaryInvariant(for: platform)
        }
        rebuildPrimaryMap()
    }

    private func rebuildPrimaryMap() {
        var map: [SharePlatform: AccountRecord] = [:]
        for item in allAccounts where item.isPrimary {
            map[item.platform] = item
        }
        for item in allAccounts where map[item.platform] == nil {
            map[item.platform] = item
        }
        self.accounts = map
    }

    private func rebuildPrimaryMapAndPersist() {
        rebuildPrimaryMap()
        revision += 1
        if let data = try? JSONEncoder().encode(allAccounts) {
            defaults.set(data, forKey: metadataKey)
        }
    }
}
