//
//  AuthCryptoTests.swift
//  YunXTests
//
//  验证 YUNX_AUTH_V2 加密备份的加解密往返、格式检测与错误口令拦截。
//

import XCTest
@testable import YunX

final class AuthCryptoTests: XCTestCase {
    func testEncryptAndDecryptRoundTrip() throws {
        let sampleJSON = #"{"app":"yunx_auth_backup","version":1,"accounts":[{"platform":"quark","cookie":"__pus=abc; __puus=def"}]}"#
        let encrypted = try AuthCrypto.encrypt(plaintext: sampleJSON, password: "yunx-secret-pass")
        XCTAssertTrue(AuthCrypto.isEncrypted(encrypted))

        let decrypted = try AuthCrypto.decrypt(base64Data: encrypted, password: "yunx-secret-pass")
        XCTAssertEqual(decrypted, sampleJSON)
    }

    func testWrongPasswordThrowsDecryptFailed() throws {
        let encrypted = try AuthCrypto.encrypt(plaintext: "hello yunx", password: "correct-password")
        XCTAssertThrowsError(try AuthCrypto.decrypt(base64Data: encrypted, password: "wrong-password"))
    }

    func testShortPasswordRejected() {
        XCTAssertThrowsError(try AuthCrypto.encrypt(plaintext: "data", password: "1234567"))
    }
}
