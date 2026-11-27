//
//  DeepLinkHandlerTests.swift
//  YunXTests
//
//  Step 3.1 系统分享扩展与 yunx:// URL Scheme 深度链接分流单元测试。
//

import XCTest
@testable import YunX

final class DeepLinkHandlerTests: XCTestCase {
    func testMakeAndParseCloudDriveDeepLink() throws {
        let raw = "夸克分享 https://pan.quark.cn/s/ab12CD34ef56 提取码：8k9P"
        let url = try XCTUnwrap(DeepLinkHandler.makeResolveURL(text: raw))
        XCTAssertEqual(url.scheme, "yunx")
        XCTAssertEqual(url.host, "resolve")

        let req = try XCTUnwrap(DeepLinkHandler.parse(url: url))
        XCTAssertEqual(req.mode, .cloud)
        XCTAssertEqual(req.rawText, raw)
    }

    func testParseVideoDeepLinkRoutesToVideoMode() throws {
        let biliText = "快来看这个视频 https://www.bilibili.com/video/BV1xx411c7mD"
        let url = try XCTUnwrap(DeepLinkHandler.makeResolveURL(text: biliText))
        let req = try XCTUnwrap(DeepLinkHandler.parse(url: url))
        XCTAssertEqual(req.mode, .video)
        XCTAssertEqual(req.rawText, biliText)

        let douyinURL = URL(string: "yunx://open?url=https%3A%2F%2Fv.douyin.com%2FiRNBho6u%2F")!
        let dyReq = try XCTUnwrap(DeepLinkHandler.parse(url: douyinURL))
        XCTAssertEqual(dyReq.mode, .video)
        XCTAssertEqual(dyReq.rawText, "https://v.douyin.com/iRNBho6u/")
    }

    func testInvalidSchemeOrEmptyPayloadIgnored() {
        XCTAssertNil(DeepLinkHandler.parse(url: URL(string: "https://pan.quark.cn/s/abc")!))
        XCTAssertNil(DeepLinkHandler.parse(url: URL(string: "yunx://resolve")!))
        XCTAssertNil(DeepLinkHandler.parse(url: URL(string: "yunx://unknown?text=abc")!))
        XCTAssertNil(DeepLinkHandler.makeResolveURL(text: "   "))
    }
}
