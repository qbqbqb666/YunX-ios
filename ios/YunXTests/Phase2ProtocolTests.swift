//
//  Phase2ProtocolTests.swift
//  YunXTests
//
//  Phase 2 协议算法、加解密、签名、GitHub 链接识别、凭证载体与下载请求头单元测试。
//

import XCTest
@testable import YunX

final class Phase2ProtocolTests: XCTestCase {

    // MARK: - 115 电脑端 RSA/XOR 协议与大整数模幂

    func testPan115BigUIntModPow() {
        // 3^65537 mod 1000000007 验证小规模模幂
        let base = BigUInt(limbs: [3])
        let mod = BigUInt(limbs: [1_000_000_007])
        let actual = base.modPow(exponent: 65537, modulus: mod)

        // 原生 UInt64 计算参考值
        var expected: UInt64 = 1
        var b: UInt64 = 3
        var e: UInt64 = 65537
        let m: UInt64 = 1_000_000_007
        while e > 0 {
            if e & 1 == 1 { expected = (expected * b) % m }
            b = (b * b) % m
            e >>= 1
        }
        XCTAssertEqual(actual.limbs, [UInt32(expected)])
    }

    func testPan115CryptoEncodeDeterministicAndFormat() throws {
        let key: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        let payload = "{\"pickcode\":\"abcdef123456\"}"
        let b64 = try Pan115Crypto.encode(payload: payload, key: key)
        guard let raw = Data(base64Encoded: b64) else {
            return XCTFail("编码结果不是合法 Base64")
        }
        // 单块 1024-bit RSA 密文应为 128 字节
        XCTAssertEqual(raw.count, 128)
        // 相同输入输出一致（固定 0xff 填充）
        let b64Again = try Pan115Crypto.encode(payload: payload, key: key)
        XCTAssertEqual(b64, b64Again)
    }

    func testPan115ConstantsCookieAndToken() {
        let cookie = "UID=103616022_A1_1700000000; CID=abc; SEID=xyz"
        XCTAssertTrue(Pan115Constants.isValidCookie(cookie))
        XCTAssertEqual(Pan115Constants.extractUserId(cookie), "103616022")

        let merged = Pan115Constants.mergeCookies(cookie, "cdn_tok=900s")
        XCTAssertEqual(merged, "\(cookie); cdn_tok=900s")

        let encoded = Pan115Constants.encodeShareToken(receiveCode: "a1b2", userId: "9988")
        let decoded = Pan115Constants.decodeShareToken(encoded)
        XCTAssertEqual(decoded.receiveCode, "a1b2")
        XCTAssertEqual(decoded.userId, "9988")
    }

    // MARK: - 139 云盘 AES-CBC / mcloud-sign / Cookie 提取

    func testC139AESRoundTrip() throws {
        let plain = "{\"getOutLinkInfoReq\":{\"linkID\":\"abc123\",\"pCaID\":\"root\"}}"
        let encrypted = try C139Crypto.encryptBody(plain)
        let decrypted = try C139Crypto.decryptBody(encrypted)
        XCTAssertEqual(decrypted, plain)
    }

    func testC139CalSignDeterministic() {
        let body = "{\"a\":1,\"b\":\"测试\"}"
        let sign1 = C139Crypto.calSign(bodyJson: body, ts: "2026-11-26 18:00:00", rand: "AbCdEf1234567890")
        let sign2 = C139Crypto.calSign(bodyJson: body, ts: "2026-11-26 18:00:00", rand: "AbCdEf1234567890")
        XCTAssertEqual(sign1.count, 32)
        XCTAssertEqual(sign1, sign1.uppercased())
        XCTAssertEqual(sign1, sign2)
    }

    func testC139AuthorizationAccountDecode() {
        let raw = Data("pc:13800138000:token123".utf8).base64EncodedString()
        let cookie = "authorization=Basic \(raw)"
        XCTAssertTrue(C139Constants.isValidCookie(cookie))
        XCTAssertEqual(C139Constants.extractAccountFull(cookie), "13800138000")
    }

    // MARK: - 迅雷 captcha_sign / 设备指纹 / JWT / 凭证编解码

    func testXunleiCaptchaSignFormat() {
        let sign = XunleiSigner.buildCaptchaSign(
            deviceId: XunleiConstants.fallbackDeviceId,
            timestampMs: "1732600000000"
        )
        XCTAssertTrue(sign.hasPrefix("1."))
        XCTAssertEqual(sign.count, 34) // "1." + 32 hex
    }

    func testXunleiDeviceSignAndCredentialPayload() {
        let devSign = XunleiSigner.buildDeviceSign(deviceId: XunleiConstants.fallbackDeviceId)
        XCTAssertTrue(devSign.hasPrefix("div101.\(XunleiConstants.fallbackDeviceId)"))
        XCTAssertEqual(devSign.count, "div101.".count + 32 + 32)

        let payload = XunleiCredentialPayload(
            accessToken: "eyJ.abc.def",
            refreshToken: "rt_123",
            deviceId: "dev_456",
            captchaToken: "cap_789",
            authType: ""
        )
        let decoded = XunleiCredentialPayload.decode(from: payload.encodedString())
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - 光鸭账号规范化与设备头

    func testGuangYaNormalizeAccountAndDeviceSign() {
        XCTAssertEqual(GuangYaConstants.normalizeAccount("13800138000"), "+86 13800138000")
        XCTAssertEqual(GuangYaConstants.normalizeAccount("+8613800138000"), "+86 13800138000")
        XCTAssertEqual(GuangYaConstants.normalizeAccount("user@example.com"), "user@example.com")

        let did = GuangYaConstants.newDeviceId()
        let sign = GuangYaConstants.newDeviceSign(deviceId: did)
        XCTAssertEqual(GuangYaConstants.deviceIdFromSign(sign, fallback: "fallback"), did)
    }

    // MARK: - GitHub 链接识别

    func testGitHubLinkParser() {
        let raw = GitHubLinkParser.parse("https://raw.githubusercontent.com/CYQawa/YunX/main/README.md")
        XCTAssertEqual(raw, .directFile(url: "https://raw.githubusercontent.com/CYQawa/YunX/main/README.md", fileName: "README.md"))

        let rel = GitHubLinkParser.parse("https://github.com/CYQawa/YunX/releases/download/v1.0/app.apk")
        XCTAssertEqual(rel, .directFile(url: "https://github.com/CYQawa/YunX/releases/download/v1.0/app.apk", fileName: "app.apk"))

        let repo = GitHubLinkParser.parse("https://github.com/CYQawa/YunX/tree/main/app")
        XCTAssertEqual(repo, .repository(owner: "CYQawa", repo: "YunX", subPath: "tree/main/app"))

        let acc = GitHubLinkParser.parse("https://github.com/CYQawa")
        XCTAssertEqual(acc, .account(owner: "CYQawa"))

        XCTAssertNil(GitHubLinkParser.parse("https://github.com/trending/swift"))
    }

    // MARK: - 全平台下载请求头校验

    func testPhase2DownloadHeaders() {
        let link = DownloadLink(fid: "1", filename: "test.bin", downloadUrl: "https://cdn.example.com/test.bin", size: 100, guestCookie: "cdn=900s")

        let h115 = DownloadHeaderBuilder.buildHeaders(platform: .pan115, credential: "UID=1_A1; SEID=2", link: link)
        XCTAssertEqual(h115["Cookie"], "UID=1_A1; SEID=2; cdn=900s")
        XCTAssertTrue((h115["User-Agent"] ?? "").contains("115Browser/"))
        XCTAssertEqual(h115["Referer"], "https://115.com/")

        let hXunlei = DownloadHeaderBuilder.buildHeaders(platform: .xunlei, credential: "", link: link)
        XCTAssertEqual(hXunlei["User-Agent"], XunleiConstants.appUA)

        let hGuangYa = DownloadHeaderBuilder.buildHeaders(platform: .guangya, credential: "", link: link)
        XCTAssertEqual(hGuangYa["Referer"], GuangYaConstants.downloadReferer)

        let hBaidu = DownloadHeaderBuilder.buildHeaders(platform: .baidu, credential: "BDUSS=xyz", link: link)
        XCTAssertEqual(hBaidu["Cookie"], "BDUSS=xyz")
        XCTAssertEqual(hBaidu["User-Agent"], BaiduConstants.uaNetdisk)

        let hGH = DownloadHeaderBuilder.buildHeaders(platform: .github, credential: "ghp_test", link: link)
        XCTAssertEqual(hGH["Authorization"], "Bearer ghp_test")
    }
}
