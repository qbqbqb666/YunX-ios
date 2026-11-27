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
}
