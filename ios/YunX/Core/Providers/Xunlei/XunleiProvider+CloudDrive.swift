//
//  XunleiProvider+CloudDrive.swift
//  YunX
//
//  迅雷网盘个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension XunleiProvider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard let payload = await prepareValidPayload(rawCredential: credential) else { return nil }
        guard let json = try? await panRequestJSON(
            url: XunleiConstants.aboutURL,
            method: "GET",
            body: nil,
            action: "GET:/drive/v1/about",
            payload: payload
        ) else { return nil }
        let node = (json["data"] as? [String: Any]) ?? json
        guard let quota = node["quota"] as? [String: Any] else { return nil }
        let total = int64Value(quota["limit"])
        let used = int64Value(quota["usage"])
        let trash = int64Value(quota["usage_in_trash"])
        return total > 0 ? CloudQuota(used: used, total: total, usedInTrash: trash) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        return try await listPersonalFiles(parentId: dirFid, payload: payload)
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        let body: [String: Any] = [
            "kind": "drive#folder",
            "name": name,
            "parent_id": parentFid,
            "space": ""
        ]
        let json = try await panRequestJSON(
            url: XunleiConstants.filesURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/files",
            payload: payload
        )
        let id = stringValue(json["id"]).isEmpty
            ? stringValue((json["file"] as? [String: Any])?["id"])
            : stringValue(json["id"])
        guard !id.isEmpty else { throw ProviderError.missingData("创建迅雷文件夹失败") }
        return id
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        _ = try await panRequestJSON(
            url: "\(XunleiConstants.filesURL)/\(urlEncode(file.fid))",
            method: "PATCH",
            body: ["name": newName],
            action: "PATCH:/drive/v1/files/\(file.fid)",
            payload: payload
        )
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        _ = try await panRequestJSON(
            url: XunleiConstants.trashURL,
            method: "POST",
            body: ["ids": ids, "space": ""],
            action: "POST:/drive/v1/files:batchTrash",
            payload: payload
        )
    }

    public func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let body: [String: Any] = [
            "ids": ids,
            "to": ["parent_id": toDirFid, "space": ""],
            "space": ""
        ]
        _ = try await panRequestJSON(
            url: XunleiConstants.moveURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/files:batchMove",
            payload: payload
        )
    }

    public func createCloudShare(
        files: [ShareFile],
        title: String,
        expire: CloudShareExpire,
        passcode: String?,
        credential: String
    ) async throws -> CloudShareResult {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw ProviderError.missingData("请选择要分享的文件") }
        let cleanPwd = (passcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var params: [String: Any] = [
            "subscribe_push": "false",
            "WithPassCodeInLink": "true",
            "with_pass_code_in_link": "true"
        ]
        if !cleanPwd.isEmpty {
            params["pass_code"] = cleanPwd
        }
        let shareTitle = title.isEmpty ? (files.first?.fname ?? "分享文件") : title
        let body: [String: Any] = [
            "file_ids": ids,
            "share_to": "copy",
            "params": params,
            "title": shareTitle,
            "restore_limit": "-1",
            "expiration_days": expire.xunleiDays
        ]
        let json = try await panRequestJSON(
            url: XunleiConstants.shareURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/share",
            payload: payload
        )
        let data = (json["data"] as? [String: Any]) ?? json
        let shareUrl = stringValue(data["share_url"])
        guard !shareUrl.isEmpty else { throw ProviderError.missingData("迅雷未返回分享链接") }
        return CloudShareResult(
            platform: .xunlei,
            shareUrl: shareUrl,
            passcode: stringValue(data["pass_code"]),
            pwdId: stringValue(data["share_id"]),
            title: stringValue(data["title"]).isEmpty ? shareTitle : stringValue(data["title"]),
            expire: expire
        )
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        return try await getFileDownloadLink(
            fileId: file.fid,
            fallbackName: file.fname,
            fallbackSize: file.fsize,
            payload: payload
        )
    }

    public func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String? {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        guard source.fileSize > 0 else {
            throw ProviderError.apiMessage("迅雷不支持上传 0 字节空文件")
        }
        let io = UploadIO(source: source, onProgress: onProgress)
        io.report(.preparing)

        var blockSize: Int64 = 0x40000
        while source.fileSize / blockSize > 0x200 && blockSize < 0x200000 {
            blockSize *= 2
        }
        let blockCount = max(1, (source.fileSize + blockSize - 1) / blockSize)
        var digests: [Data] = []
        digests.reserveCapacity(Int(blockCount))
        for idx in 0..<blockCount {
            let start = idx * blockSize
            let end = min(source.fileSize, start + blockSize)
            digests.append(try io.digestBytes(.sha1, start: start, end: end))
        }
        let gcid = UploadSigning.gcid(blockDigests: digests)
        let body: [String: Any] = [
            "kind": "drive#file",
            "parent_id": parentFid,
            "name": source.fileName,
            "size": source.fileSize,
            "hash": gcid,
            "upload_type": "UPLOAD_TYPE_RESUMABLE",
            "space": ""
        ]
        let task = try await panRequestJSON(
            url: XunleiConstants.filesURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/files",
            payload: payload
        )
        let node = (task["data"] as? [String: Any]) ?? task
        let fileId = stringValue((node["file"] as? [String: Any])?["id"]).isEmpty
            ? stringValue(node["id"])
            : stringValue((node["file"] as? [String: Any])?["id"])
        if let resumable = node["resumable"] as? [String: Any],
           let params = resumable["params"] as? [String: Any],
           !params.isEmpty {
            try await io.s3Multipart(
                endpoint: stringValue(params["endpoint"]),
                bucket: stringValue(params["bucket"]),
                objectKey: stringValue(params["key"]),
                accessKey: stringValue(params["access_key_id"]),
                secretKey: stringValue(params["access_key_secret"]),
                region: "xunlei",
                securityToken: stringValue(params["security_token"])
            )
        }
        io.report(.finishing, sent: source.fileSize)
        return fileId.isEmpty ? nil : fileId
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard let payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        _ = try await restoreShare(
            shareId: session.shareId,
            passCodeToken: session.stoken,
            fileIds: [file.fid],
            parentId: toDirFid,
            payload: payload
        )
    }
}
