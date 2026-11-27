//
//  QuarkUploadHelper.swift
//  YunX
//
//  夸克 / UC 共用个人盘上传引擎：
//  file/upload/pre → file/update/hash（命中即秒传）→ file/upload/auth 分片 PUT 到 OSS → XML 回调合并 → file/upload/finish。
//

import Foundation

public struct QuarkUploadHelper: Sendable {
    public let apiBase: String
    public let product: String
    public let origin: String
    public let userAgent: String
    public let post: @Sendable (_ url: String, _ body: [String: Any]) async throws -> [String: Any]

    private static let defaultPartSize: Int64 = 8 * 1024 * 1024
    private static let ossAgent = "aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit"

    public init(
        apiBase: String,
        product: String,
        origin: String,
        userAgent: String,
        post: @escaping @Sendable (_ url: String, _ body: [String: Any]) async throws -> [String: Any]
    ) {
        self.apiBase = apiBase
        self.product = product
        self.origin = origin
        self.userAgent = userAgent
        self.post = post
    }

    private func endpoint(_ path: String) -> String {
        "\(apiBase)/1/clouddrive/\(path)?pr=\(product)&fr=pc"
    }

    public func upload(io: UploadIO, parentFid: String) async throws -> String? {
        let file = io.source
        guard file.fileSize > 0 else {
            throw ProviderError.apiMessage("暂不支持上传 0 字节空文件")
        }
        io.report(.preparing)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let pre = try await post(endpoint("file/upload/pre"), [
            "ccp_hash_update": true,
            "dir_name": "",
            "file_name": file.fileName,
            "format_type": file.mimeType,
            "pdir_fid": parentFid,
            "size": file.fileSize,
            "l_created_at": nowMs,
            "l_updated_at": nowMs,
            "same_path_reuse": false
        ])

        guard let taskId = pre["task_id"] as? String, !taskId.isEmpty else {
            throw ProviderError.missingData("上传预处理未返回 task_id")
        }

        let md5 = try io.digestHex(.md5)
        let sha1 = try io.digestHex(.sha1)
        let hashResult = try await post(endpoint("file/update/hash"), [
            "md5": md5,
            "sha1": sha1,
            "task_id": taskId
        ])
        if (hashResult["finish"] as? Bool) == true {
            io.report(.finishing, sent: file.fileSize)
            return nil
        }

        let bucket = pre["bucket"] as? String ?? ""
        let objectKey = pre["obj_key"] as? String ?? ""
        let uploadId = pre["upload_id"] as? String ?? ""
        let uploadUrlStr = pre["upload_url"] as? String ?? ""
        guard let host = URL(string: uploadUrlStr)?.host, !host.isEmpty else {
            throw ProviderError.missingData("上传预处理未返回有效的对象存储节点")
        }
        guard !bucket.isEmpty, !objectKey.isEmpty, !uploadId.isEmpty else {
            throw ProviderError.missingData("上传预处理返回的对象存储凭据不完整")
        }

        let bucketHost = host.hasPrefix("\(bucket).") ? host : "\(bucket).\(host)"
        let objectPath = objectKey.split(separator: "/", omittingEmptySubsequences: false)
            .map { UploadSigning.rfc3986Escape(String($0)) }
            .joined(separator: "/")
        let address = "https://\(bucketHost)/\(objectPath)"

        let metaObj = pre["metadata"] as? [String: Any]
        let declaredPart = (metaObj?["part_size"] as? NSNumber)?.int64Value ?? Self.defaultPartSize
        let partSize = declaredPart > 0 ? declaredPart : Self.defaultPartSize
        let authInfo: Any = pre["auth_info"] ?? ""

        func authorize(meta: String) async throws -> String {
            let res = try await post(endpoint("file/upload/auth"), [
                "auth_info": authInfo,
                "auth_meta": meta,
                "task_id": taskId
            ])
            guard let key = res["auth_key"] as? String, !key.isEmpty else {
                throw ProviderError.missingData("获取分片上传授权签名失败")
            }
            return key
        }

        let partCount = max(1, (file.fileSize + partSize - 1) / partSize)
        var etags: [String] = []
        for idx in 0..<partCount {
            let start = idx * partSize
            let stop = min(file.fileSize, start + partSize)
            let date = UploadSigning.httpDate()
            let partNumber = idx + 1
            let meta = "PUT\n\n\(file.mimeType)\n\(date)\n" +
                "x-oss-date:\(date)\nx-oss-user-agent:\(Self.ossAgent)\n" +
                "/\(bucket)/\(objectKey)?partNumber=\(partNumber)&uploadId=\(uploadId)"
            let authKey = try await authorize(meta: meta)
            let resp = try await io.send(
                url: "\(address)?partNumber=\(partNumber)&uploadId=\(uploadId)",
                method: "PUT",
                headers: [
                    "Authorization": authKey,
                    "Referer": "\(origin)/",
                    "User-Agent": userAgent,
                    "x-oss-date": date,
                    "x-oss-user-agent": Self.ossAgent
                ],
                contentType: file.mimeType,
                start: start,
                end: stop,
                retries: 1
            )
            guard resp.isSuccessful else {
                throw ProviderError.apiMessage("分片上传失败（HTTP \(resp.statusCode)）")
            }
            let etag = resp.header("ETag")
            guard !etag.isEmpty else {
                throw ProviderError.missingData("分片上传未返回 ETag")
            }
            etags.append(etag)
        }

        io.report(.finishing, sent: file.fileSize)
        let xml = UploadSigning.completeXml(etags: etags)
        let date = UploadSigning.httpDate()
        let contentMD5 = UploadSigning.md5Data(Data(xml.utf8)).base64EncodedString()

        guard let callbackObj = pre["callback"],
              JSONSerialization.isValidJSONObject(callbackObj),
              let callbackJsonData = try? JSONSerialization.data(withJSONObject: callbackObj) else {
            throw ProviderError.missingData("上传预处理缺少 callback 回调参数")
        }
        let callbackB64 = callbackJsonData.base64EncodedString()
        let completeMeta = "POST\n\(contentMD5)\napplication/xml\n\(date)\n" +
            "x-oss-callback:\(callbackB64)\nx-oss-date:\(date)\nx-oss-user-agent:\(Self.ossAgent)\n" +
            "/\(bucket)/\(objectKey)?uploadId=\(uploadId)"
        let completeAuth = try await authorize(meta: completeMeta)
        let merged = try await io.send(
            url: "\(address)?uploadId=\(uploadId)",
            method: "POST",
            headers: [
                "Authorization": completeAuth,
                "Content-MD5": contentMD5,
                "Referer": "\(origin)/",
                "User-Agent": userAgent,
                "x-oss-callback": callbackB64,
                "x-oss-date": date,
                "x-oss-user-agent": Self.ossAgent
            ],
            contentType: "application/xml",
            textBody: xml,
            retries: 0
        )
        guard merged.isSuccessful && !UploadSigning.xmlError(merged.body) else {
            throw ProviderError.apiMessage("分片合并失败（HTTP \(merged.statusCode)）")
        }

        _ = try await post(endpoint("file/upload/finish"), [
            "obj_key": objectKey,
            "task_id": taskId
        ])
        return nil
    }
}
