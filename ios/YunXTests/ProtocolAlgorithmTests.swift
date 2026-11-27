//
//  ProtocolAlgorithmTests.swift
//  YunXTests
//
//  网盘协议算法单测：123 CRC32 签名与解包、蓝奏 acw_sc__v2 人机校验、Cookie 合并与续期。
//

import XCTest
@testable import YunX

final class ProtocolAlgorithmTests: XCTestCase {
    func testPan123CRC32AndSignDeterminism() {
        // 标准 IEEE CRC32("123456789") == 0xcbf43926
        XCTAssertEqual(Pan123Signer.crc32Hex("123456789"), "cbf43926")

        let s1 = Pan123Signer.makeSign(path: "/b/api/share/download/info", timestamp: 1_700_000_000, randomSeed: 123_456)
        let s2 = Pan123Signer.makeSign(path: "/b/api/share/download/info", timestamp: 1_700_000_000, randomSeed: 123_456)
        XCTAssertEqual(s1.authKey, s2.authKey)
        XCTAssertEqual(s1.authValue, s2.authValue)
        XCTAssertTrue(s1.authValue.hasPrefix("1700000000-123456-"))
    }

    func testPan123DownloadURLDecoding() {
        let target = "https://download-cdn.cjjd19.com/test/file.zip?sig=abc"
        let b64 = Data(target.utf8).base64EncodedString()
        XCTAssertEqual(Pan123Signer.decodeDownloadURL(b64), target)
        XCTAssertEqual(Pan123Signer.decodeDownloadURL("https://www.123pan.com/download-v2?params=\(b64)&other=1"), target)
    }

    func testLanzouAcwScV2LengthAndHex() {
        let arg1 = "0123456789abcdef0123456789abcdef01234567"
        let cookie = LanzouChallenge.computeAcwScV2(arg1: arg1)
        XCTAssertEqual(cookie.count, 40)
        XCTAssertTrue(cookie.allSatisfy { $0.isHexDigit })
    }

    func testCookieHelperMergeAndPugs() {
        let original = "foo=1; __pus=old_pus; __puus=old_puus"
        let merged = CookieHelper.merge(
            original: original,
            setCookies: ["__puus=new_puus; Path=/; HttpOnly", "ignored=xyz"]
        )
        XCTAssertTrue(merged.contains("__puus=new_puus"))
        XCTAssertTrue(merged.contains("__pus=old_pus"))
        XCTAssertFalse(merged.contains("ignored=xyz"))

        let stripped = CookieHelper.withoutPuus(merged)
        XCTAssertFalse(stripped.contains("__puus="))
        XCTAssertTrue(stripped.contains("__pus=old_pus"))

        let pugs = CookieHelper.extractPugs(from: ["__pugs=guest_token_123; Path=/; Max-Age=10800"])
        XCTAssertEqual(pugs, "__pugs=guest_token_123")
    }
}
