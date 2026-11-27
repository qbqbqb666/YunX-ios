//
//  ILanzouAndMultiAccountTests.swift
//  YunXTests
//
//  Step 2.3（蓝奏优享 AES/Token/路由）与 Step 2.4（同平台多账号切换、备注、精准续期与 .yunx 备份互通）单元测试。
//

import XCTest
@testable import YunX

final class ILanzouAndMultiAccountTests: XCTestCase {
    func testILanzouConstantsAESAndTokenEncoding() {
        let encrypted = ILanzouConstants.aesHex("12345|67890")
        XCTAssertEqual(encrypted.count, 32)
        XCTAssertEqual(encrypted, encrypted.lowercased())
        XCTAssertEqual(encrypted, ILanzouConstants.aesHex("12345|67890"))

        XCTAssertEqual(ILanzouConstants.encodeToken("abc:def+1"), "abc:def%2B1")
        XCTAssertEqual(ILanzouConstants.stripPrefix("d:10086"), "10086")
        XCTAssertEqual(ILanzouConstants.stripPrefix("f:99999"), "99999")
        XCTAssertEqual(ILanzouConstants.stripPrefix("raw"), "raw")

        let payload = ILanzouCredentialPayload(appToken: "tok_1234567890abcdef", uuid: "abcd1234efgh5678", userId: "42", account: "13800138000")
        let decoded = ILanzouCredentialPayload.decode(from: payload.encodedString())
        XCTAssertEqual(decoded, payload)

        let bare = ILanzouCredentialPayload.decode(from: "bare_token_1234567890")
        XCTAssertEqual(bare?.appToken, "bare_token_1234567890")
    }

    @MainActor
    func testILanzouRoutingAndHeaders() {
        let container = AppContainer()
        XCTAssertTrue(SharePlatform.ilanzou.isSupported)
        XCTAssertTrue(SharePlatform.ilanzou.supportsGuestDownload)
        XCTAssertNotNil(container.provider(for: .ilanzou))

        let headers = DownloadHeaderBuilder.buildHeaders(
            platform: .ilanzou,
            credential: "",
            link: DownloadLink(fid: "f:1", filename: "a.zip", downloadUrl: "https://cdn.ilanzou.com/a.zip", size: 10)
        )
        XCTAssertEqual(headers["Referer"], ILanzouConstants.downloadReferer)
        XCTAssertEqual(headers["Origin"], ILanzouConstants.downloadOrigin)
    }

    @MainActor
    func testMultiAccountLifecycleSwitchRemarkAndBackupRoundTrip() throws {
        let suiteName = "yunx.multiaccount.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = "com.yunx.ios.test.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let store = AccountStore(keychain: keychain, defaults: defaults)

        // 1. 首个账号写入平台默认槽位
        let first = try XCTUnwrap(store.saveAccount(
            platform: .quark,
            credential: "__pus=a1; __puus=b1",
            nickname: "大号"
        ))
        XCTAssertEqual(first.id, "quark")
        XCTAssertTrue(first.isPrimary)
        XCTAssertEqual(store.credential(for: .quark), "__pus=a1; __puus=b1")

        // 2. 同平台新增第二个账号并激活
        let second = try XCTUnwrap(store.saveAccount(
            platform: .quark,
            credential: "__pus=a2; __puus=b2",
            nickname: "小号",
            asNewAccount: true,
            activateNew: true
        ))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(store.accounts(for: .quark).count, 2)
        XCTAssertEqual(store.credential(for: .quark), "__pus=a2; __puus=b2")

        // 3. 备注与精准回写不串号
        store.updateRemark(accountId: second.id, remark: "会员号")
        XCTAssertEqual(store.record(for: .quark)?.displayTitle, "会员号")
        store.updateCredentialIfMatching(platform: .quark, merged: "__pus=a1_new; __puus=b1", matching: "__pus=a1; __puus=b1")
        XCTAssertEqual(store.credential(forAccountId: first.id, platform: .quark), "__pus=a1_new; __puus=b1")
        XCTAssertEqual(store.credential(forAccountId: second.id, platform: .quark), "__pus=a2; __puus=b2")

        // 4. 一键切换活跃账号
        store.setPrimary(accountId: first.id, for: .quark)
        XCTAssertEqual(store.credential(for: .quark), "__pus=a1_new; __puus=b1")

        // 5. 加密备份导出 → 新实例导入完整还原多账号
        let backup = AuthBackupService(accountStore: store)
        let encrypted = try backup.exportEncrypted(password: "TestPass1234")

        let defaults2 = UserDefaults(suiteName: "\(suiteName).restore")!
        defer { defaults2.removePersistentDomain(forName: "\(suiteName).restore") }
        let keychain2 = KeychainStore(service: "\(service).restore")
        let store2 = AccountStore(keychain: keychain2, defaults: defaults2)
        let backup2 = AuthBackupService(accountStore: store2)

        let count = try backup2.importBackup(content: encrypted, password: "TestPass1234")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(store2.accounts(for: .quark).count, 2)
        XCTAssertEqual(store2.credential(for: .quark), "__pus=a1_new; __puus=b1")

        // 6. 删除当前主账号自动晋升剩余账号
        store2.removeAccount(for: .quark)
        XCTAssertEqual(store2.accounts(for: .quark).count, 1)
        XCTAssertEqual(store2.credential(for: .quark), "__pus=a2; __puus=b2")

        // 清理测试 Keychain
        store.removeAllAccounts(for: .quark)
        store2.removeAllAccounts(for: .quark)
    }
}
