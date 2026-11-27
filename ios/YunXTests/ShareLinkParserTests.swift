//
//  ShareLinkParserTests.swift
//  YunXTests
//
//  全 11 平台网盘分享链接与提取码识别单元测试。
//

import XCTest
@testable import YunX

final class ShareLinkParserTests: XCTestCase {
    func testQuarkAndUC() {
        let quark = ShareLinkParser.parse("我用夸克网盘分享了文件 https://pan.quark.cn/s/ab12CD34ef56 提取码：8k9P")
        XCTAssertEqual(quark?.platform, .quark)
        XCTAssertEqual(quark?.shareId, "ab12CD34ef56")
        XCTAssertEqual(quark?.pwd, "8k9P")

        let uc = ShareLinkParser.parse("https://drive.uc.cn/s/9876abcDEF?pwd=xy12")
        XCTAssertEqual(uc?.platform, .uc)
        XCTAssertEqual(uc?.shareId, "9876abcDEF")
        XCTAssertEqual(uc?.pwd, "xy12")
    }

    func testPan123Variants() {
        let a = ShareLinkParser.parse("https://www.123pan.com/s/2785Vv-T4Ded 提取码:abcd")
        XCTAssertEqual(a?.platform, .pan123)
        XCTAssertEqual(a?.shareId, "2785Vv-T4Ded")
        XCTAssertEqual(a?.pwd, "abcd")

        let b = ShareLinkParser.parse("https://www.123865.com/s/1122Aa-Bb33?pwd=9988")
        XCTAssertEqual(b?.platform, .pan123)
        XCTAssertEqual(b?.shareId, "1122Aa-Bb33")
        XCTAssertEqual(b?.pwd, "9988")

        let c = ShareLinkParser.parse("https://www.123pan.cn/api/srr?sk=9988Kk-Zz11")
        XCTAssertEqual(c?.platform, .pan123)
        XCTAssertEqual(c?.shareId, "9988Kk-Zz11")
    }

    func testLanzouAndILanzouDistinction() {
        let ilanzou = ShareLinkParser.parse("https://www.ilanzou.com/s/abcDEF12?pwd=1234")
        XCTAssertEqual(ilanzou?.platform, .ilanzou)
        XCTAssertEqual(ilanzou?.shareId, "abcDEF12")

        let lanzouLegacy = ShareLinkParser.parse("https://wwx.lanzoui.com/iAbCdEf1234 密码：6a7b")
        XCTAssertEqual(lanzouLegacy?.platform, .lanzou)
        XCTAssertEqual(lanzouLegacy?.shareId, "iAbCdEf1234")
        XCTAssertEqual(lanzouLegacy?.pwd, "6a7b")

        let lanznNew = ShareLinkParser.parse("https://user123.lanzn.com/iXnuF4c8sqmb?pass=4321")
        XCTAssertEqual(lanznNew?.platform, .lanzou)
        XCTAssertEqual(lanznNew?.shareId, "iXnuF4c8sqmb")
        XCTAssertEqual(lanznNew?.pwd, "4321")
    }

    func testOtherPlatforms() {
        let baidu = ShareLinkParser.parse("https://pan.baidu.com/s/1AbCdEfGhIjK?pwd=a1b2")
        XCTAssertEqual(baidu?.platform, .baidu)
        XCTAssertEqual(baidu?.shareId, "AbCdEfGhIjK")
        XCTAssertEqual(baidu?.pwd, "a1b2")

        let xunlei = ShareLinkParser.parse("https://pan.xunlei.com/s/VNxyz_123-45 提取码：qwer")
        XCTAssertEqual(xunlei?.platform, .xunlei)
        XCTAssertEqual(xunlei?.shareId, "VNxyz_123-45")
        XCTAssertEqual(xunlei?.pwd, "qwer")

        let pan115 = ShareLinkParser.parse("https://115cdn.com/s/sw123456789?password=abcd")
        XCTAssertEqual(pan115?.platform, .pan115)
        XCTAssertEqual(pan115?.shareId, "sw123456789")
        XCTAssertEqual(pan115?.pwd, "abcd")

        let c139 = ShareLinkParser.parse("https://yun.139.com/shareweb/#/w/i/2i5c123456 提取码：8888")
        XCTAssertEqual(c139?.platform, .c139)
        XCTAssertEqual(c139?.shareId, "2i5c123456")

        let guangya = ShareLinkParser.parse("https://www.guangyapan.com/s/gy_001-aa")
        XCTAssertEqual(guangya?.platform, .guangya)
        XCTAssertEqual(guangya?.shareId, "gy_001-aa")

        let github = ShareLinkParser.parse("https://github.com/qbqbqb666/YunX-ios")
        XCTAssertEqual(github?.platform, .github)
        XCTAssertEqual(github?.shareId, "qbqbqb666/YunX-ios")
    }
}
