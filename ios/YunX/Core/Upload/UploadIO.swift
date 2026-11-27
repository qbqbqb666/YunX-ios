//
//  UploadIO.swift
//  YunX
//
//  个人云盘统一上传 I/O 引擎：
//  - 流式区间哈希（MD5 / SHA-1 / SHA-256），大文件不爆内存；
//  - 原始字节分片与 multipart/form-data 定长上传，保留精确 Content-Type（不自动追加 charset）；
//  - 内置阿里云 OSS V1 分片直传与 AWS S3 V4 分片直传，支持实时进度回调与取消。
//

import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum UploadPhase: String, Sendable, Equatable {
    case preparing
    case uploading
    case finishing

    public var label: String {
        switch self {
        case .preparing: return "正在校验文件…"
        case .uploading: return "正在上传…"
        case .finishing: return "正在合并落库…"
        }
    }
}

public struct UploadProgress: Sendable, Equatable {
    public let phase: UploadPhase
    public let sentBytes: Int64
    public let totalBytes: Int64

    public init(phase: UploadPhase, sentBytes: Int64, totalBytes: Int64) {
        self.phase = phase
        self.sentBytes = max(0, sentBytes)
        self.totalBytes = max(0, totalBytes)
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return phase == .finishing ? 1.0 : 0 }
        return min(1.0, max(0.0, Double(sentBytes) / Double(totalBytes)))
    }
}

public struct UploadSource: Sendable {
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String

    public init(fileURL: URL, fileName: String? = nil, fileSize: Int64? = nil, mimeType: String? = nil) throws {
        self.fileURL = fileURL
        self.fileName = (fileName?.isEmpty == false ? fileName! : fileURL.lastPathComponent)
        if let fileSize {
            self.fileSize = fileSize
        } else {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            self.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }
        if let mimeType, !mimeType.isEmpty {
            self.mimeType = mimeType
        } else {
            let ext = (self.fileName as NSString).pathExtension
            if !ext.isEmpty, let ut = UTType(filenameExtension: ext), let mime = ut.preferredMIMEType {
                self.mimeType = mime
            } else {
                self.mimeType = "application/octet-stream"
            }
        }
    }
}

public struct UploadHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: String

    public var isSuccessful: Bool { (200..<300).contains(statusCode) }

    public func header(_ name: String) -> String {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return ""
    }

    public func jsonObject() -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public enum UploadHashAlgorithm: String, Sendable {
    case md5
    case sha1
    case sha256
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onSent: @Sendable (Int64) -> Void

    init(onSent: @escaping @Sendable (Int64) -> Void) {
        self.onSent = onSent
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onSent(totalBytesSent)
    }
}

public final class UploadIO: @unchecked Sendable {
    public let source: UploadSource
    private let onProgress: @Sendable (UploadProgress) -> Void
    private let session: URLSession

    private static let ioBufferSize = 64 * 1024
    private static let minPartSize: Int64 = 8 * 1024 * 1024

    public init(source: UploadSource, onProgress: @escaping @Sendable (UploadProgress) -> Void) {
        self.source = source
        self.onProgress = onProgress

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 4
        config.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func report(_ phase: UploadPhase, sent: Int64 = 0) {
        let clamped = min(max(0, sent), source.fileSize)
        onProgress(UploadProgress(phase: phase, sentBytes: clamped, totalBytes: source.fileSize))
    }

    // MARK: - 流式区间哈希

    public func digestHex(_ algorithm: UploadHashAlgorithm, start: Int64 = 0, end: Int64? = nil) throws -> String {
        UploadSigning.hex(try digestBytes(algorithm, start: start, end: end))
    }

    public func digestBytes(_ algorithm: UploadHashAlgorithm, start: Int64 = 0, end: Int64? = nil) throws -> Data {
        let actualEnd = min(end ?? source.fileSize, source.fileSize)
        let length = max(0, actualEnd - start)

        let handle = try FileHandle(forReadingFrom: source.fileURL)
        defer { try? handle.close() }
        if start > 0 {
            try handle.seek(toOffset: UInt64(start))
        }

        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()

        var remaining = length
        var readTotal: Int64 = 0
        while remaining > 0 {
            if Task.isCancelled { throw CancellationError() }
            let toRead = Int(min(remaining, Int64(Self.ioBufferSize)))
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else { break }
            switch algorithm {
            case .md5: md5.update(data: chunk)
            case .sha1: sha1.update(data: chunk)
            case .sha256: sha256.update(data: chunk)
            }
            remaining -= Int64(chunk.count)
            readTotal += Int64(chunk.count)
            report(.preparing, sent: start + readTotal)
        }
        guard readTotal == length else {
            throw ProviderError.apiMessage("读取本地文件不完整，请重试")
        }

        switch algorithm {
        case .md5: return Data(md5.finalize())
        case .sha1: return Data(sha1.finalize())
        case .sha256: return Data(sha256.finalize())
        }
    }

    // MARK: - 通用分片 / 表单 / 文本上传请求

    public func send(
        url urlString: String,
        method: String = "PUT",
        headers: [String: String] = [:],
        contentType: String? = nil,
        start: Int64 = 0,
        end: Int64? = nil,
        fields: [(String, String)] = [],
        fieldName: String = "file",
        fileName: String? = nil,
        textBody: String? = nil,
        retries: Int = 0
    ) async throws -> UploadHTTPResponse {
        guard let url = URL(string: urlString) else {
            throw HTTPClientError.invalidURL(urlString)
        }

        let actualEnd = min(end ?? source.fileSize, source.fileSize)
        let effectiveFileName = fileName ?? source.fileName
        let effectiveMime = contentType ?? source.mimeType

        var attempt = 0
        while true {
            if Task.isCancelled { throw CancellationError() }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            for (k, v) in headers where !v.isEmpty {
                request.setValue(v, forHTTPHeaderField: k)
            }

            do {
                let (data, response): (Data, URLResponse)
                if let textBody {
                    let bodyData = Data(textBody.utf8)
                    request.setValue(contentType ?? "application/xml", forHTTPHeaderField: "Content-Type")
                    (data, response) = try await session.upload(for: request, from: bodyData)
                } else {
                    let tempPayloadURL = try materializePayloadFile(
                        start: start,
                        end: actualEnd,
                        mimeType: effectiveMime,
                        fields: fields,
                        fieldName: fieldName,
                        fileName: effectiveFileName,
                        request: &request
                    )
                    defer { try? FileManager.default.removeItem(at: tempPayloadURL) }

                    let baseOffset = start
                    let maxEnd = actualEnd
                    let progressDelegate = UploadProgressDelegate { [weak self] sentInChunk in
                        let current = min(maxEnd, baseOffset + sentInChunk)
                        self?.report(.uploading, sent: current)
                    }
                    (data, response) = try await session.upload(for: request, fromFile: tempPayloadURL, delegate: progressDelegate)
                    report(.uploading, sent: actualEnd)
                }

                guard let http = response as? HTTPURLResponse else {
                    throw HTTPClientError.nonHTTPResponse
                }
                var headerMap: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String {
                        headerMap[ks] = vs
                    }
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                return UploadHTTPResponse(statusCode: http.statusCode, headers: headerMap, body: text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt >= retries { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
    }

    // MARK: - 阿里云 OSS V1 分片直传（光鸭）

    public func ossMultipart(
        endpoint: String,
        bucket: String,
        objectKey: String,
        accessKey: String,
        secretKey: String,
        securityToken: String = "",
        contentType: String? = nil
    ) async throws {
        guard !endpoint.isEmpty, !bucket.isEmpty, !objectKey.isEmpty, !accessKey.isEmpty, !secretKey.isEmpty else {
            throw ProviderError.missingData("OSS 上传凭据不完整")
        }
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://\(base)"
        }
        guard let parsed = URL(string: base), let scheme = parsed.scheme, let host = parsed.host else {
            throw ProviderError.apiMessage("OSS Endpoint 无效")
        }
        let finalHost = host.hasPrefix("\(bucket).") ? host : "\(bucket).\(host)"
        let objectPath = objectKey.split(separator: "/", omittingEmptySubsequences: false)
            .map { UploadSigning.rfc3986Escape(String($0)) }
            .joined(separator: "/")
        let baseURL = "\(scheme)://\(finalHost)/\(objectPath)"

        func ossRequest(
            method: String,
            parameters: [String: String] = [:],
            textBody: String? = nil,
            start: Int64? = nil,
            end: Int64? = nil
        ) async throws -> UploadHTTPResponse {
            let date = UploadSigning.httpDate()
            let type = contentType ?? (start == nil ? "application/xml" : source.mimeType)
            let canonicalQuery = parameters.keys.sorted().map { k -> String in
                let v = parameters[k] ?? ""
                return v.isEmpty ? UploadSigning.rfc3986Escape(k) : "\(UploadSigning.rfc3986Escape(k))=\(UploadSigning.rfc3986Escape(v))"
            }.joined(separator: "&")
            let canonical = canonicalQuery.isEmpty ? "" : "?\(canonicalQuery)"
            let auth = UploadSigning.ossV1Authorization(
                accessKey: accessKey,
                secretKey: secretKey,
                method: method,
                contentType: type,
                date: date,
                canonicalResource: "/\(bucket)/\(objectKey)\(canonical)",
                securityToken: securityToken
            )
            var headers: [String: String] = [
                "Authorization": auth,
                "Date": date,
                "Content-Type": type
            ]
            if !securityToken.isEmpty {
                headers["x-oss-security-token"] = securityToken
            }
            let targetURL = canonicalQuery.isEmpty ? baseURL : "\(baseURL)?\(canonicalQuery)"
            return try await send(
                url: targetURL,
                method: method,
                headers: headers,
                contentType: type,
                start: start ?? 0,
                end: end ?? source.fileSize,
                textBody: start == nil ? (textBody ?? "") : nil,
                retries: start == nil ? 0 : 1
            )
        }

        if source.fileSize == 0 {
            let resp = try await ossRequest(method: "PUT", start: 0, end: 0)
            guard resp.isSuccessful && !UploadSigning.xmlError(resp.body) else {
                throw ProviderError.apiMessage("OSS 空文件上传失败（HTTP \(resp.statusCode)）")
            }
            return
        }

        let initiated = try await ossRequest(method: "POST", parameters: ["uploads": ""])
        guard initiated.isSuccessful && !UploadSigning.xmlError(initiated.body) else {
            throw ProviderError.apiMessage("初始化 OSS 分片上传失败（HTTP \(initiated.statusCode)）")
        }
        let uploadId = UploadSigning.xmlValue(initiated.body, tag: "UploadId")
        guard !uploadId.isEmpty else {
            throw ProviderError.missingData("OSS 未返回 UploadId")
        }

        var completed = false
        do {
            let partSize = max(Self.minPartSize, (source.fileSize + 8999) / 9000)
            var etags: [String] = []
            var offset: Int64 = 0
            while offset < source.fileSize {
                let stop = min(source.fileSize, offset + partSize)
                let resp = try await ossRequest(
                    method: "PUT",
                    parameters: ["partNumber": "\(etags.count + 1)", "uploadId": uploadId],
                    start: offset,
                    end: stop
                )
                guard resp.isSuccessful else {
                    throw ProviderError.apiMessage("OSS 分片上传失败（HTTP \(resp.statusCode)）")
                }
                let etag = resp.header("ETag")
                guard !etag.isEmpty else {
                    throw ProviderError.missingData("OSS 分片响应缺少 ETag")
                }
                etags.append(etag)
                offset = stop
            }
            report(.finishing, sent: source.fileSize)
            let merged = try await ossRequest(
                method: "POST",
                parameters: ["uploadId": uploadId],
                textBody: UploadSigning.completeXml(etags: etags)
            )
            guard merged.isSuccessful && !UploadSigning.xmlError(merged.body) else {
                throw ProviderError.apiMessage("OSS 合并分片失败（HTTP \(merged.statusCode)）")
            }
            completed = true
        } catch {
            if !completed && !Task.isCancelled {
                _ = try? await ossRequest(method: "DELETE", parameters: ["uploadId": uploadId])
            }
            throw error
        }
    }

    // MARK: - AWS S3 V4 分片直传（123 兜底 / 迅雷）

    public func s3Multipart(
        endpoint: String,
        bucket: String,
        objectKey: String,
        accessKey: String,
        secretKey: String,
        region: String,
        securityToken: String = "",
        pathStyle: Bool = false
    ) async throws {
        guard !endpoint.isEmpty, !bucket.isEmpty, !objectKey.isEmpty, !accessKey.isEmpty, !secretKey.isEmpty else {
            throw ProviderError.missingData("S3 上传凭据不完整")
        }
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://\(base)"
        }
        guard let parsed = URL(string: base), let scheme = parsed.scheme, let host = parsed.host else {
            throw ProviderError.apiMessage("S3 Endpoint 无效")
        }
        let finalHost = (pathStyle || host.hasPrefix("\(bucket).")) ? host : "\(bucket).\(host)"
        let encodedKey = objectKey.split(separator: "/", omittingEmptySubsequences: false)
            .map { UploadSigning.rfc3986Escape(String($0)) }
            .joined(separator: "/")
        let canonicalPath = pathStyle ? "/\(bucket)/\(encodedKey)" : "/\(encodedKey)"
        let origin = "\(scheme)://\(finalHost)"

        func s3Request(
            method: String,
            parameters: [String: String] = [:],
            textBody: String? = nil,
            start: Int64? = nil,
            end: Int64? = nil
        ) async throws -> UploadHTTPResponse {
            let stamp = UploadSigning.isoStamp()
            let contentHash: String
            if let start {
                contentHash = try digestHex(.sha256, start: start, end: end ?? source.fileSize)
            } else {
                contentHash = UploadSigning.sha256Hex(Data((textBody ?? "").utf8))
            }
            let canonicalQuery = parameters.keys.sorted().map { k -> String in
                "\(UploadSigning.rfc3986Escape(k))=\(UploadSigning.rfc3986Escape(parameters[k] ?? ""))"
            }.joined(separator: "&")

            let auth = UploadSigning.s3V4Authorization(
                accessKey: accessKey,
                secretKey: secretKey,
                region: region,
                method: method,
                canonicalPath: canonicalPath,
                canonicalQuery: canonicalQuery,
                host: finalHost,
                amzDate: stamp,
                contentSha256: contentHash,
                securityToken: securityToken
            )
            var headers: [String: String] = [
                "Host": finalHost,
                "x-amz-content-sha256": contentHash,
                "x-amz-date": stamp,
                "Authorization": auth
            ]
            if !securityToken.isEmpty {
                headers["x-amz-security-token"] = securityToken
            }
            let querySuffix = canonicalQuery.isEmpty ? "" : "?\(canonicalQuery)"
            return try await send(
                url: "\(origin)\(canonicalPath)\(querySuffix)",
                method: method,
                headers: headers,
                contentType: start == nil ? "application/xml" : source.mimeType,
                start: start ?? 0,
                end: end ?? source.fileSize,
                textBody: start == nil ? (textBody ?? "") : nil,
                retries: start == nil ? 0 : 1
            )
        }

        let partSize = max(Self.minPartSize, (source.fileSize + 8999) / 9000)
        if source.fileSize <= partSize {
            let resp = try await s3Request(method: "PUT", start: 0, end: source.fileSize)
            guard resp.isSuccessful && !UploadSigning.xmlError(resp.body) else {
                throw ProviderError.apiMessage("S3 上传失败（HTTP \(resp.statusCode)）")
            }
            return
        }

        let initiated = try await s3Request(method: "POST", parameters: ["uploads": ""])
        guard initiated.isSuccessful && !UploadSigning.xmlError(initiated.body) else {
            throw ProviderError.apiMessage("初始化 S3 分片上传失败（HTTP \(initiated.statusCode)）")
        }
        let uploadId = UploadSigning.xmlValue(initiated.body, tag: "UploadId")
        guard !uploadId.isEmpty else {
            throw ProviderError.missingData("S3 未返回 UploadId")
        }

        var completed = false
        do {
            var etags: [String] = []
            var offset: Int64 = 0
            while offset < source.fileSize {
                let stop = min(source.fileSize, offset + partSize)
                let resp = try await s3Request(
                    method: "PUT",
                    parameters: ["partNumber": "\(etags.count + 1)", "uploadId": uploadId],
                    start: offset,
                    end: stop
                )
                guard resp.isSuccessful else {
                    throw ProviderError.apiMessage("S3 分片上传失败（HTTP \(resp.statusCode)）")
                }
                let etag = resp.header("ETag")
                guard !etag.isEmpty else {
                    throw ProviderError.missingData("S3 分片响应缺少 ETag")
                }
                etags.append(etag)
                offset = stop
            }
            report(.finishing, sent: source.fileSize)
            let merged = try await s3Request(
                method: "POST",
                parameters: ["uploadId": uploadId],
                textBody: UploadSigning.completeXml(etags: etags)
            )
            guard merged.isSuccessful && !UploadSigning.xmlError(merged.body) else {
                throw ProviderError.apiMessage("S3 合并分片失败（HTTP \(merged.statusCode)）")
            }
            completed = true
        } catch {
            if !completed && !Task.isCancelled {
                _ = try? await s3Request(method: "DELETE", parameters: ["uploadId": uploadId])
            }
            throw error
        }
    }

    // MARK: - 临时分片负载构造（避免整文件加载入内存）

    private func materializePayloadFile(
        start: Int64,
        end: Int64,
        mimeType: String,
        fields: [(String, String)],
        fieldName: String,
        fileName: String,
        request: inout URLRequest
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yunx-upload-\(UUID().uuidString).part")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: tempURL)
        defer { try? writer.close() }

        let boundary: String? = fields.isEmpty ? nil : "----YunXUpload\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        if let boundary {
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var head = ""
            for (k, v) in fields {
                head += "--\(boundary)\r\n"
                head += "Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n"
                head += "\(v)\r\n"
            }
            let safeName = fileName.replacingOccurrences(of: "\"", with: "")
            head += "--\(boundary)\r\n"
            head += "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\n"
            head += "Content-Type: \(mimeType)\r\n\r\n"
            try writer.write(contentsOf: Data(head.utf8))
        } else {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            }
        }

        let reader = try FileHandle(forReadingFrom: source.fileURL)
        defer { try? reader.close() }
        if start > 0 {
            try reader.seek(toOffset: UInt64(start))
        }
        var remaining = max(0, end - start)
        while remaining > 0 {
            if Task.isCancelled { throw CancellationError() }
            let toRead = Int(min(remaining, Int64(Self.ioBufferSize)))
            guard let chunk = try reader.read(upToCount: toRead), !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            remaining -= Int64(chunk.count)
        }
        guard remaining == 0 else {
            throw ProviderError.apiMessage("读取上传分片不完整")
        }

        if let boundary {
            try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        }
        return tempURL
    }
}
