//
//  Phase3CloudDriveTests.swift
//  YunXTests
//
//  Phase 3 个人云盘模型、路由装配、目录根 ID、123 ShareId 提取与百度 App 通道参数单元测试。
//

import XCTest
@testable import YunX

final class Phase3CloudDriveTests: XCTestCase {
    func testCloudQuotaUsageRatio() {
        let zero = CloudQuota(used: 100, total: 0)
        XCTAssertEqual(zero.usageRatio, 0)

        let half = CloudQuota(used: 512, total: 1024)
        XCTAssertEqual(half.usageRatio, 0.5, accuracy: 0.0001)

        let over = CloudQuota(used: 2048, total: 1024)
        XCTAssertEqual(over.usageRatio, 1.0, accuracy: 0.0001)
    }

    func testCloudDrivePlatformsAndRootIds() {
        XCTAssertEqual(SharePlatform.cloudDrivePlatforms.count, 8)
        XCTAssertTrue(SharePlatform.quark.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.uc.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.pan123.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.pan115.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.c139.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.xunlei.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.guangya.supportsCloudDrive)
        XCTAssertTrue(SharePlatform.baidu.supportsCloudDrive)
        XCTAssertFalse(SharePlatform.lanzou.supportsCloudDrive)
        XCTAssertFalse(SharePlatform.github.supportsCloudDrive)

        // 139 分享根为 "root"，但个人盘管理根为 "/"
        XCTAssertEqual(SharePlatform.c139.rootDirFid, "root")
        XCTAssertEqual(SharePlatform.c139.cloudRootDirFid, "/")
        XCTAssertEqual(SharePlatform.baidu.cloudRootDirFid, "/")
        XCTAssertEqual(SharePlatform.quark.cloudRootDirFid, "0")
        XCTAssertEqual(SharePlatform.pan115.cloudRootDirFid, "0")
        XCTAssertEqual(SharePlatform.xunlei.cloudRootDirFid, "")
        XCTAssertEqual(SharePlatform.guangya.cloudRootDirFid, "")
    }

    @MainActor
    func testAppContainerCloudProviderRouting() {
        let container = AppContainer()
        for platform in SharePlatform.cloudDrivePlatforms {
            XCTAssertNotNil(container.cloudProvider(for: platform), "\(platform.displayName) 应注册个人网盘提供者")
        }
        XCTAssertNil(container.cloudProvider(for: .lanzou))
        XCTAssertNil(container.cloudProvider(for: .github))
        XCTAssertNil(container.cloudProvider(for: .ilanzou))
    }

    func testPan123ShareIdExtractionFromFidToken() {
        XCTAssertEqual(Pan123Provider.extractShareId(fromFidToken: "1816216065-0|abcetag|m0"), "1816216065")
        XCTAssertEqual(Pan123Provider.extractShareId(fromFidToken: ""), "")
    }

    func testBaiduAppChannelDerivedParams() {
        let cookie = "BDUSS=test_bduss_value; STOKEN=test_stoken"
        let bdstoken = BaiduProvider.appBdstoken(cookie: cookie)
        let devuid = BaiduProvider.appDeviceId(cookie: cookie)
        XCTAssertEqual(bdstoken.count, 32)
        XCTAssertEqual(bdstoken, bdstoken.lowercased())
        XCTAssertTrue(devuid.hasSuffix("|0"))
        XCTAssertEqual(devuid.count, 34)
    }

    func testCloudShareExpireMappingsAndFormatting() {
        XCTAssertEqual(CloudShareExpire.forever.daysOrNull, nil)
        XCTAssertEqual(CloudShareExpire.oneDay.daysOrNull, 1)
        XCTAssertEqual(CloudShareExpire.sevenDays.daysOrNull, 7)
        XCTAssertEqual(CloudShareExpire.thirtyDays.daysOrNull, 30)

        XCTAssertEqual(CloudShareExpire.forever.baiduPeriod, 0)
        XCTAssertEqual(CloudShareExpire.sevenDays.baiduPeriod, 7)
        XCTAssertEqual(CloudShareExpire.forever.xunleiDays, "-1")
        XCTAssertEqual(CloudShareExpire.thirtyDays.xunleiDays, "30")
        XCTAssertEqual(CloudShareExpire.forever.pan115Duration, "-1")
        XCTAssertEqual(CloudShareExpire.threeDays.pan115Duration, "3")
        XCTAssertEqual(CloudShareExpire.fifteenDays.pan115Duration, "15")
        XCTAssertEqual(CloudShareExpire.forever.pan123ExpirationString(), "2099-12-12T08:00:00+08:00")

        XCTAssertEqual(CloudShareExpire.options(for: .pan115).count, 5)
        XCTAssertEqual(CloudShareExpire.options(for: .quark).count, 4)

        let res = CloudShareResult(
            platform: .quark,
            shareUrl: "https://pan.quark.cn/s/abc123",
            passcode: "8k9p",
            pwdId: "abc123",
            title: "测试文档.pdf",
            expire: .sevenDays
        )
        XCTAssertTrue(res.formattedCopyText.contains("https://pan.quark.cn/s/abc123"))
        XCTAssertTrue(res.formattedCopyText.contains("提取码：8k9p"))
    }

    func testBaiduPathAndFsIdHelpers() {
        let dir = ShareFile(fid: "/文档/设计", fname: "设计", fsize: 0, isdir: true, pdirFid: "/文档", fidToken: "987654321")
        XCTAssertEqual(BaiduProvider.baiduPath(of: dir), "/文档/设计")
        XCTAssertEqual(BaiduProvider.baiduFsId(of: dir), "987654321")

        let file = ShareFile(fid: "123456789", fname: "a.pdf", fsize: 100, isdir: false, pdirFid: "/文档", fidToken: "/文档/a.pdf")
        XCTAssertEqual(BaiduProvider.baiduPath(of: file), "/文档/a.pdf")
        XCTAssertEqual(BaiduProvider.baiduFsId(of: file), "123456789")
    }
}
