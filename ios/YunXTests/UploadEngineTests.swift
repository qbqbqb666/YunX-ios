//
//  UploadEngineTests.swift
//  YunXTests
//
//  个人云盘上传签名算法与流式区间哈希单元测试：OSS V1、S3 V4、迅雷 gcid、XML 合并报文与 UploadIO 流式摘要。
//

import CryptoKit
import XCTest
@testable import YunX

final class UploadEngineTests: XCTestCase {
    func testOSSV1AuthorizationFormatAndDeterminism() {
        let auth = UploadSigning.ossV1Authorization(
            accessKey: "LTAI_TEST_KEY",
            secretKey: "test_secret_123",
            method: "PUT",
            contentType: "application/octet-stream",
            date: "Fri, 27 Nov 2026 06:00:00 GMT",
            canonicalResource: "/demo-bucket/folder/file.bin?partNumber=1&uploadId=abc",
            securityToken: "sts-token-xyz"
        )
        XCTAssertTrue(auth.hasPrefix("OSS LTAI_TEST_KEY:"))
        let second = UploadSigning.ossV1Authorization(
            accessKey: "LTAI_TEST_KEY",
            secretKey: "test_secret_123",
            method: "PUT",
            contentType: "application/octet-stream",
            date: "Fri, 27 Nov 2026 06:00:00 GMT",
            canonicalResource: "/demo-bucket/folder/file.bin?partNumber=1&uploadId=abc",
            securityToken: "sts-token-xyz"
        )
        XCTAssertEqual(auth, second)
    }

    func testS3V4AuthorizationContainsRequiredComponents() {
        let auth = UploadSigning.s3V4Authorization(
            accessKey: "AKIA_TEST",
            secretKey: "SECRET_TEST",
            region: "xunlei",
            method: "PUT",
            canonicalPath: "/bucket/test.bin",
            canonicalQuery: "partNumber=1&uploadId=u1",
            host: "s3.example.com",
            amzDate: "20261127T060000Z",
            contentSha256: UploadSigning.sha256Hex(Data("hello".utf8)),
            securityToken: "tok"
        )
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIA_TEST/20261127/xunlei/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token"))
        XCTAssertTrue(auth.contains("Signature="))
    }

    func testXunleiGCIDAndXMLHelpers() {
        let b1 = Data(Insecure.SHA1.hash(data: Data("block-1".utf8)))
        let b2 = Data(Insecure.SHA1.hash(data: Data("block-2".utf8)))
        let gcid = UploadSigning.gcid(blockDigests: [b1, b2])
        XCTAssertEqual(gcid.count, 40)
        XCTAssertEqual(gcid, gcid.uppercased())

        let xml = UploadSigning.completeXml(etags: ["\"etag1\"", "\"etag2\""])
        XCTAssertTrue(xml.contains("<PartNumber>1</PartNumber>"))
        XCTAssertTrue(xml.contains("&quot;etag1&quot;"))
        XCTAssertTrue(UploadSigning.xmlError("<Error><Code>AccessDenied</Code></Error>"))
        XCTAssertFalse(UploadSigning.xmlError("<InitiateMultipartUploadResult><UploadId>u123</UploadId></InitiateMultipartUploadResult>"))
        XCTAssertEqual(
            UploadSigning.xmlValue("<InitiateMultipartUploadResult><UploadId>u123</UploadId></InitiateMultipartUploadResult>", tag: "UploadId"),
            "u123"
        )
    }

    func testUploadIOStreamingDigestsAndRange() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("yunx-upload-test-\(UUID().uuidString).txt")
        let payload = Data("YunX-iOS-Upload-Stream-Payload-1234567890".utf8)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let source = try UploadSource(fileURL: tmp)
        XCTAssertEqual(source.fileSize, Int64(payload.count))
        XCTAssertEqual(source.mimeType, "text/plain")

        let io = UploadIO(source: source, onProgress: { _ in })
        let fullMD5 = try io.digestHex(.md5)
        let expectedMD5 = UploadSigning.hex(Data(Insecure.MD5.hash(data: payload)))
        XCTAssertEqual(fullMD5, expectedMD5)

        let sliceSHA256 = try io.digestHex(.sha256, start: 0, end: 8)
        let expectedSlice = UploadSigning.sha256Hex(payload.prefix(8))
        XCTAssertEqual(sliceSHA256, expectedSlice)
    }
}
