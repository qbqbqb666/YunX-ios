//
//  ThumbnailLoader.swift
//  YunX
//
//  列表缩略图异步加载器与内存/磁盘二级缓存：
//  - 独立 ephemeral URLSession，显式禁用系统 Cookie 罐，绝不串号；
//  - 仅允许 HTTPS，30x 跨域名跳转自动剥离 Cookie / Authorization 防凭据泄漏；
//  - L1 内存缓存（同步命中，滚动零闪烁）+ L2 磁盘缓存（SHA-256 命名，64MB 自动淘汰）；
//  - 同 URL 并发请求去重 + ImageIO 后台降采样，确保列表流畅不卡顿。
//

import CryptoKit
import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// 缩略图重定向与安全请求策略（独立抽离便于单元测试验证）
public enum ThumbnailRedirectPolicy {
    private static let sensitiveHeaderNames: Set<String> = [
        "cookie",
        "authorization",
        "proxy-authorization"
    ]

    /// 校验并净化 30x 跳转后的请求：
    /// 1. 禁止降级到非 HTTPS；
    /// 2. 跨域跳转时剥离 Cookie / Authorization，避免登录态泄密给外部图床/CDN；
    /// 3. 始终关闭系统自动 Cookie 处理。
    public static func sanitizedRedirectRequest(
        from originalRequest: URLRequest?,
        to newRequest: URLRequest
    ) -> URLRequest? {
        guard let targetURL = newRequest.url,
              targetURL.scheme?.lowercased() == "https",
              let targetHost = targetURL.host?.lowercased(),
              !targetHost.isEmpty else {
            return nil
        }

        var sanitized = newRequest
        sanitized.httpShouldHandleCookies = false

        let originalHost = originalRequest?.url?.host?.lowercased()
        let isSameHost = (originalHost != nil && originalHost == targetHost)
        if !isSameHost, let fields = sanitized.allHTTPHeaderFields {
            for key in fields.keys where sensitiveHeaderNames.contains(key.lowercased()) {
                sanitized.setValue(nil, forHTTPHeaderField: key)
            }
        }
        return sanitized
    }
}

private final class ThumbnailRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let next = ThumbnailRedirectPolicy.sanitizedRedirectRequest(from: task.originalRequest, to: request)
        completionHandler(next)
    }
}

#if canImport(UIKit)
public final class ThumbnailLoader: @unchecked Sendable {
    public static let shared = ThumbnailLoader()

    /// 支持渲染列表缩略图的图片扩展名集合（对齐安卓端：仅图片开启，避免各网盘视频/文档封面不一致）
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "avif"
    ]

    /// 单张缩略图最大允许响应体（4 MB），防止异常大图拖垮内存
    public static let maxResponseBytes = 4 * 1024 * 1024

    private let memoryCache: NSCache<NSString, UIImage>
    private let coordinator: ThumbnailFetchCoordinator

    public init(
        diskCacheDirectory: URL? = nil,
        maxDiskBytes: Int64 = 64 * 1024 * 1024,
        session: URLSession? = nil
    ) {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 32 * 1024 * 1024
        self.memoryCache = cache

        let directory = diskCacheDirectory ?? Self.defaultDiskCacheDirectory()
        let effectiveSession = session ?? Self.makeDefaultSession()
        self.coordinator = ThumbnailFetchCoordinator(
            diskCacheDirectory: directory,
            maxDiskBytes: maxDiskBytes,
            session: effectiveSession
        )
    }

    public static func isEligibleImageFile(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return supportedImageExtensions.contains(ext)
    }

    public static func cacheKey(for url: String, targetPixelSize: Int) -> String {
        let input = "\(url)#\(max(targetPixelSize, 32))"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 同步读取 L1 内存缓存，供 SwiftUI 列表行首复用时零闪烁直接渲染
    public func cachedImage(for thumbnail: FileThumbnail, targetPixelSize: Int = 126) -> UIImage? {
        let key = Self.cacheKey(for: thumbnail.url, targetPixelSize: targetPixelSize)
        return memoryCache.object(forKey: key as NSString)
    }

    /// 异步加载缩略图（L1 内存 → L2 磁盘 → 并发去重网络拉取 + 后台降采样）
    public func loadImage(for thumbnail: FileThumbnail, targetPixelSize: Int = 126) async -> UIImage? {
        let trimmed = thumbnail.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }

        let safeSize = max(targetPixelSize, 32)
        let key = Self.cacheKey(for: trimmed, targetPixelSize: safeSize)
        if let hit = memoryCache.object(forKey: key as NSString) {
            return hit
        }

        let normalizedThumb = FileThumbnail(url: trimmed, headers: thumbnail.headers)
        guard let image = await coordinator.load(
            thumbnail: normalizedThumb,
            url: url,
            cacheKey: key,
            targetPixelSize: safeSize
        ) else {
            return nil
        }

        let cost = Self.estimatedMemoryCost(of: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    /// 清空 L1 内存与 L2 磁盘缩略图缓存
    public func clearCache() async {
        memoryCache.removeAllObjects()
        await coordinator.clearDiskCache()
    }

    /// 仅清空 L1 内存缓存（用于内存告警或测试验证磁盘回读）
    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// 当前磁盘缓存占用字节数
    public func diskCacheUsageBytes() async -> Int64 {
        await coordinator.diskCacheUsageBytes()
    }

    // MARK: - 内部工具

    private static func defaultDiskCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("YunXThumbnails", isDirectory: true)
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: ThumbnailRedirectDelegate(), delegateQueue: nil)
    }

    private static func estimatedMemoryCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return max(cg.bytesPerRow * cg.height, 1024)
        }
        return max(Int(image.size.width * image.size.height * image.scale * image.scale * 4), 1024)
    }

    /// 使用 ImageIO 按目标像素尺寸高效降采样解码
    internal static func downsample(data: Data, maxPixelSize: Int) -> UIImage? {
        guard !data.isEmpty, data.count <= maxResponseBytes else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 32)
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                return UIImage(cgImage: cgImage)
            }
        }
        return UIImage(data: data)
    }
}

private actor ThumbnailFetchCoordinator {
    private let diskCacheDirectory: URL
    private let maxDiskBytes: Int64
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(diskCacheDirectory: URL, maxDiskBytes: Int64, session: URLSession) {
        self.diskCacheDirectory = diskCacheDirectory
        self.maxDiskBytes = maxDiskBytes
        self.session = session
    }

    func load(
        thumbnail: FileThumbnail,
        url: URL,
        cacheKey: String,
        targetPixelSize: Int
    ) async -> UIImage? {
        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            // 1. 尝试命中 L2 磁盘缓存
            if let diskImage = self.readFromDisk(cacheKey: cacheKey, targetPixelSize: targetPixelSize) {
                return diskImage
            }

            // 2. 发起受控网络请求
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            for (header, value) in thumbnail.headers where !value.isEmpty {
                request.setValue(value, forHTTPHeaderField: header)
            }

            do {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      !data.isEmpty,
                      data.count <= ThumbnailLoader.maxResponseBytes else {
                    return nil
                }
                guard let image = ThumbnailLoader.downsample(data: data, maxPixelSize: targetPixelSize) else {
                    return nil
                }
                self.writeToDisk(data: data, cacheKey: cacheKey)
                return image
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil
        return result
    }

    func clearDiskCache() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: diskCacheDirectory.path) else { return }
        if let items = try? fm.contentsOfDirectory(at: diskCacheDirectory, includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.removeItem(at: item)
            }
        }
    }

    func diskCacheUsageBytes() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for item in items {
            if let values = try? item.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func diskFileURL(for cacheKey: String) -> URL {
        diskCacheDirectory.appendingPathComponent("\(cacheKey).thumb", isDirectory: false)
    }

    private func readFromDisk(cacheKey: String, targetPixelSize: Int) -> UIImage? {
        let fileURL = diskFileURL(for: cacheKey)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let image = ThumbnailLoader.downsample(data: data, maxPixelSize: targetPixelSize) else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        // 更新访问时间用于简易 LRU 淘汰
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return image
    }

    private func writeToDisk(data: Data, cacheKey: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: diskCacheDirectory.path) {
            try? fm.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
        }
        let fileURL = diskFileURL(for: cacheKey)
        try? data.write(to: fileURL, options: .atomic)
        evictDiskCacheIfNeeded()
    }

    private func evictDiskCacheIfNeeded() {
        guard maxDiskBytes > 0 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return
        }

        var entries: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for url in items {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            total += size
            entries.append((url, size, modified))
        }

        guard total > maxDiskBytes else { return }
        // 按最后修改时间升序删除，裁剪至上限的 80%
        let target = Int64(Double(maxDiskBytes) * 0.8)
        entries.sort { $0.modified < $1.modified }
        for entry in entries {
            guard total > target else { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
#endif
