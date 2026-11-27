//
//  VideoAccountStore.swift
//  YunX
//
//  视频解析平台账号存储（哔哩哔哩 / 小红书 / Pixiv 等）：
//  敏感 Cookie 独立落 iOS Keychain，昵称元数据落 UserDefaults，并兼容安卓 .yunx 加密备份。
//

import Foundation
import Observation

public struct VideoAccountRecord: Codable, Equatable, Identifiable, Sendable {
    public let platform: VideoPlatform
    public var nickname: String
    public var updatedAt: Int64

    public var id: String { platform.rawValue }

    public init(
        platform: VideoPlatform,
        nickname: String = "",
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.platform = platform
        self.nickname = nickname
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
public final class VideoAccountStore {
    public private(set) var accounts: [VideoPlatform: VideoAccountRecord] = [:]

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let metadataKey = "yunx.video.accounts.metadata.v1"

    public init(keychain: KeychainStore = .shared, defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        loadMetadata()
    }

    public func isLoggedIn(_ platform: VideoPlatform) -> Bool {
        guard let c = cookie(for: platform) else { return false }
        return !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func cookie(for platform: VideoPlatform) -> String? {
        keychain.read(forKey: keychainKey(for: platform))
    }

    public func record(for platform: VideoPlatform) -> VideoAccountRecord? {
        accounts[platform]
    }

    public func saveCookie(
        platform: VideoPlatform,
        cookie: String,
        nickname: String = "",
        updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keychain.save(trimmed, forKey: keychainKey(for: platform))
        accounts[platform] = VideoAccountRecord(
            platform: platform,
            nickname: nickname.isEmpty ? (accounts[platform]?.nickname ?? "") : nickname,
            updatedAt: updatedAt
        )
        persistMetadata()
    }

    public func removeAccount(for platform: VideoPlatform) {
        keychain.delete(forKey: keychainKey(for: platform))
        accounts.removeValue(forKey: platform)
        persistMetadata()
    }

    private func keychainKey(for platform: VideoPlatform) -> String {
        "video.credential.\(platform.rawValue)"
    }

    private func loadMetadata() {
        guard let data = defaults.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([VideoAccountRecord].self, from: data) else {
            return
        }
        var map: [VideoPlatform: VideoAccountRecord] = [:]
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
