//
//  VideoParserTests.swift
//  YunXTests
//
//  Step 2.5 视频平台解析模块单元测试：7 平台链接识别、微博 mid2id、小红书去水印换算、
//  B站清晰度标签、VideoHTTP 工具与视频账号 .yunx 加密备份互通。
//

import XCTest
@testable import YunX

final class VideoParserTests: XCTestCase {
    func testVideoLinkParserAllSevenPlatforms() {
        let dyShort = VideoLinkParser.parse("7.43 复制打开抖音 https://v.douyin.com/iRNBho6u/ 看看这个视频")
        XCTAssertEqual(dyShort?.platform, .douyin)
        XCTAssertTrue(dyShort?.isShortLink == true)

        let dyLong = VideoLinkParser.parse("https://www.douyin.com/video/7345678901234567890")
        XCTAssertEqual(dyLong?.platform, .douyin)
        XCTAssertEqual(dyLong?.id, "7345678901234567890")
        XCTAssertFalse(dyLong?.isShortLink == true)

        let xhs = VideoLinkParser.parse("小红书笔记 https://www.xiaohongshu.com/explore/65a1b2c3d4e5f60708090a1b?xsec_token=abc")
        XCTAssertEqual(xhs?.platform, .xhs)
        XCTAssertEqual(xhs?.id, "65a1b2c3d4e5f60708090a1b")

        let xhsShort = VideoLinkParser.parse("http://xhslink.com/a/BcDeFg123456")
        XCTAssertEqual(xhsShort?.platform, .xhs)
        XCTAssertTrue(xhsShort?.isShortLink == true)

        let ks = VideoLinkParser.parse("https://v.kuaishou.com/abcDEF12")
        XCTAssertEqual(ks?.platform, .kuaishou)
        XCTAssertTrue(ks?.isShortLink == true)

        let wb = VideoLinkParser.parse("https://weibo.com/1234567890/P5kWdcfDe")
        XCTAssertEqual(wb?.platform, .weibo)
        XCTAssertEqual(wb?.kind, "status")
        XCTAssertEqual(wb?.id, "P5kWdcfDe")

        let ac = VideoLinkParser.parse("https://www.acfun.cn/v/ac45678901")
        XCTAssertEqual(ac?.platform, .acfun)
        XCTAssertEqual(ac?.id, "45678901")

        let bili = VideoLinkParser.parse("https://www.bilibili.com/video/BV1xx411c7mD?p=1")
        XCTAssertEqual(bili?.platform, .bilibili)
        XCTAssertEqual(bili?.id, "BV1xx411c7mD")

        let biliShort = VideoLinkParser.parse("https://b23.tv/AbCdEf1")
        XCTAssertEqual(biliShort?.platform, .bilibili)
        XCTAssertTrue(biliShort?.isShortLink == true)

        let pixiv = VideoLinkParser.parse("https://www.pixiv.net/artworks/123456789")
        XCTAssertEqual(pixiv?.platform, .pixiv)
        XCTAssertEqual(pixiv?.id, "123456789")
    }

    func testWeiboMid2IdAndXhsWatermarkFreeAndHelpers() {
        // 经典微博 mid -> Base62 id 测试用例
        let wid = WeiboVideoParser.mid2id("3501756485200075")
        XCTAssertFalse(wid.isEmpty)
        XCTAssertEqual(wid, "z0JH2lOMb")

        let rawXhs = "http://sns-webpic-qc.xhscdn.com/202501011200/0f5eabc/1040g00831234567890!nd_dft_wlteh_webp_3"
        let cleanXhs = XhsVideoParser.watermarkFreeOrRaw(rawXhs)
        XCTAssertEqual(cleanXhs, "https://sns-img-bd.xhscdn.com/1040g00831234567890")

        XCTAssertEqual(BilibiliVideoParser.qualityLabel(80), "1080P")
        XCTAssertEqual(BilibiliVideoParser.qualityLabel(120), "4K")
        XCTAssertEqual(VideoHTTP.secureURL("http://cdn.example.com/a.jpg"), "https://cdn.example.com/a.jpg")
        XCTAssertEqual(VideoHTTP.secureURL("//cdn.example.com/a.jpg"), "https://cdn.example.com/a.jpg")

        let html = #"<script>window.__INITIAL_STATE__ = {"ok":true};</script>"#
        XCTAssertEqual(VideoHTTP.extractInlineJSON(html: html, key: "window.__INITIAL_STATE__"), #"{"ok":true}"#)
    }

    @MainActor
    func testVideoAccountBackupRoundTrip() throws {
        let suite = "yunx.video.backup.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = "com.yunx.ios.video.test.\(UUID().uuidString)"
        let kc = KeychainStore(service: service)
        let accStore = AccountStore(keychain: kc, defaults: defaults)
        let videoStore = VideoAccountStore(keychain: kc, defaults: defaults)
        videoStore.saveCookie(platform: .bilibili, cookie: "SESSDATA=test_sess_123", nickname: "测试UP")
        videoStore.saveCookie(platform: .pixiv, cookie: "PHPSESSID=999_abcdef", nickname: "")

        let backup = AuthBackupService(accountStore: accStore, videoAccountStore: videoStore)
        let encrypted = try backup.exportEncrypted(password: "VideoBackup99")

        let defaults2 = UserDefaults(suiteName: "\(suite).2")!
        defer { defaults2.removePersistentDomain(forName: "\(suite).2") }
        let kc2 = KeychainStore(service: "\(service).2")
        let accStore2 = AccountStore(keychain: kc2, defaults: defaults2)
        let videoStore2 = VideoAccountStore(keychain: kc2, defaults: defaults2)
        let backup2 = AuthBackupService(accountStore: accStore2, videoAccountStore: videoStore2)

        let restored = try backup2.importBackup(content: encrypted, password: "VideoBackup99")
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(videoStore2.cookie(for: .bilibili), "SESSDATA=test_sess_123")
        XCTAssertEqual(videoStore2.record(for: .bilibili)?.nickname, "测试UP")
        XCTAssertEqual(videoStore2.cookie(for: .pixiv), "PHPSESSID=999_abcdef")

        videoStore.removeAccount(for: .bilibili)
        videoStore.removeAccount(for: .pixiv)
        videoStore2.removeAccount(for: .bilibili)
        videoStore2.removeAccount(for: .pixiv)
    }
}
