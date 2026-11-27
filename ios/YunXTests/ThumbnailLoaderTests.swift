//
//  ThumbnailLoaderTests.swift
//  YunXTests
//
//  缩略图加载器单元测试：HTTPS 校验、跨域名重定向防 Cookie 泄密、L1/L2 二级缓存与磁盘淘汰。
//

import UIKit
import XCTest
@testable import YunX

private final class StubThumbnailURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ThumbnailLoaderTests: XCTestCase {
    private var tempCacheDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YunXThumbTests-\(UUID().uuidString)", isDirectory: true)
        StubThumbnailURLProtocol.requestCount = 0
        StubThumbnailURLProtocol.handler = nil
    }

    override func tearDownWithError() throws {
        StubThumbnailURLProtocol.handler = nil
        if let tempCacheDir {
            try? FileManager.default.removeItem(at: tempCacheDir)
        }
        try super.tearDownWithError()
    }

    func testRedirectPolicyStripsCredentialsCrossHostAndBlocksDowngrade() {
        var original = URLRequest(url: URL(string: "https://drive-pc.quark.cn/thumb/1.jpg")!)
        original.setValue("sid=secret_cookie", forHTTPHeaderField: "Cookie")
        original.setValue("Bearer secret_token", forHTTPHeaderField: "Authorization")
        original.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")

        // 同域名跳转保留 Cookie / Authorization
        var sameHostNext = URLRequest(url: URL(string: "https://drive-pc.quark.cn/thumb/2.jpg")!)
        sameHostNext.allHTTPHeaderFields = original.allHTTPHeaderFields
        let allowedSame = ThumbnailRedirectPolicy.sanitizedRedirectRequest(from: original, to: sameHostNext)
        XCTAssertNotNil(allowedSame)
        XCTAssertEqual(allowedSame?.value(forHTTPHeaderField: "Cookie"), "sid=secret_cookie")
        XCTAssertEqual(allowedSame?.value(forHTTPHeaderField: "Authorization"), "Bearer secret_token")
        XCTAssertEqual(allowedSame?.httpShouldHandleCookies, false)

        // 跨域名跳转剥离 Cookie 与 Authorization，但保留 Referer
        var crossHostNext = URLRequest(url: URL(string: "https://cdn.example-img.com/thumb/2.jpg")!)
        crossHostNext.allHTTPHeaderFields = original.allHTTPHeaderFields
        let sanitizedCross = ThumbnailRedirectPolicy.sanitizedRedirectRequest(from: original, to: crossHostNext)
        XCTAssertNotNil(sanitizedCross)
        XCTAssertNil(sanitizedCross?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sanitizedCross?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(sanitizedCross?.value(forHTTPHeaderField: "Referer"), "https://pan.quark.cn/")
        XCTAssertEqual(sanitizedCross?.httpShouldHandleCookies, false)

        // 降级到 HTTP 必须直接拦截
        let httpDowngrade = URLRequest(url: URL(string: "http://drive-pc.quark.cn/thumb/2.jpg")!)
        XCTAssertNil(ThumbnailRedirectPolicy.sanitizedRedirectRequest(from: original, to: httpDowngrade))
    }

    func testImageEligibilityAndRejectsNonHTTPS() async {
        XCTAssertTrue(ThumbnailLoader.isEligibleImageFile("IMG_001.JPG"))
        XCTAssertTrue(ThumbnailLoader.isEligibleImageFile("banner.webp"))
        XCTAssertTrue(ThumbnailLoader.isEligibleImageFile("live.heic"))
        XCTAssertFalse(ThumbnailLoader.isEligibleImageFile("movie.mp4"))
        XCTAssertFalse(ThumbnailLoader.isEligibleImageFile("archive.zip"))

        let loader = makeStubLoader()
        let httpThumb = FileThumbnail(url: "http://example.com/pic.png")
        let img = await loader.loadImage(for: httpThumb)
        XCTAssertNil(img)
        XCTAssertEqual(StubThumbnailURLProtocol.requestCount, 0)
    }

    func testMemoryAndDiskCacheRoundTripAndClear() async throws {
        let pngData = try XCTUnwrap(Self.makeSamplePNGData(width: 240, height: 240))
        let targetURL = "https://img.yunx.test/photo-1.png"

        var capturedCookie: String?
        var capturedReferer: String?
        StubThumbnailURLProtocol.handler = { request in
            capturedCookie = request.value(forHTTPHeaderField: "Cookie")
            capturedReferer = request.value(forHTTPHeaderField: "Referer")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, pngData)
        }

        let loader = makeStubLoader()
        let thumb = FileThumbnail(
            url: targetURL,
            headers: [
                "Cookie": "uid=42",
                "Referer": "https://pan.quark.cn/"
            ]
        )

        // 首次加载走网络并写入 L1 + L2
        let first = await loader.loadImage(for: thumb, targetPixelSize: 126)
        XCTAssertNotNil(first)
        XCTAssertEqual(StubThumbnailURLProtocol.requestCount, 1)
        XCTAssertEqual(capturedCookie, "uid=42")
        XCTAssertEqual(capturedReferer, "https://pan.quark.cn/")
        XCTAssertNotNil(loader.cachedImage(for: thumb, targetPixelSize: 126))
        let diskBytes = await loader.diskCacheUsageBytes()
        XCTAssertGreaterThan(diskBytes, 0)

        // L1 命中不重复发请求
        let second = await loader.loadImage(for: thumb, targetPixelSize: 126)
        XCTAssertNotNil(second)
        XCTAssertEqual(StubThumbnailURLProtocol.requestCount, 1)

        // 清空 L1 后从 L2 磁盘回读，仍不发网络请求
        loader.clearMemoryCache()
        XCTAssertNil(loader.cachedImage(for: thumb, targetPixelSize: 126))
        let third = await loader.loadImage(for: thumb, targetPixelSize: 126)
        XCTAssertNotNil(third)
        XCTAssertEqual(StubThumbnailURLProtocol.requestCount, 1)
        XCTAssertNotNil(loader.cachedImage(for: thumb, targetPixelSize: 126))

        // 清空全部缓存
        await loader.clearCache()
        XCTAssertNil(loader.cachedImage(for: thumb, targetPixelSize: 126))
        let afterClearBytes = await loader.diskCacheUsageBytes()
        XCTAssertEqual(afterClearBytes, 0)
    }

    // MARK: - Helpers

    private func makeStubLoader() -> ThumbnailLoader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubThumbnailURLProtocol.self]
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        return ThumbnailLoader(diskCacheDirectory: tempCacheDir, maxDiskBytes: 2 * 1024 * 1024, session: session)
    }

    private static func makeSamplePNGData(width: Int, height: Int) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData()
    }
}
