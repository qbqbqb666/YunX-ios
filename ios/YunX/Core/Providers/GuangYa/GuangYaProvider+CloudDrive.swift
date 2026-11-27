//
//  GuangYaProvider+CloudDrive.swift
//  YunX
//
//  光鸭云盘个人空间管理、移动、创建分享与分享转存实现（独立分区文件）。
//

import Foundation

extension GuangYaProvider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else { return nil }
        guard let json = try? await businessPost(
            url: GuangYaConstants.getAssetsURL,
            body: [:],
            deviceId: payload.deviceId,
            token: payload.accessToken
        ), let data = dataOf(json) else {
            return nil
        }
        let total = int64Value(data["totalSpaceSize"])
        let used = int64Value(data["usedSpaceSize"])
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        return try await listCloudFiles(parentId: dirFid, payload: payload)
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        return try await createDir(parentId: parentFid, name: name, payload: payload)
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        let json = try await businessPost(
            url: GuangYaConstants.renameURL,
            body: ["fileId": file.fid, "newName": newName],
            deviceId: payload.deviceId,
            token: payload.accessToken
        )
        try checkBusiness(json, fallback: "光鸭重命名失败")
        if let taskId = dataOf(json).map({ stringValue($0["taskId"]) }), !taskId.isEmpty {
            try await waitTask(taskId: taskId, payload: payload)
        }
    }

    public func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let json = try await businessPost(
            url: GuangYaConstants.moveFileURL,
            body: ["fileIds": ids, "parentId": toDirFid],
            deviceId: payload.deviceId,
            token: payload.accessToken
        )
        try checkBusiness(json, fallback: "光鸭移动失败")
        if let taskId = dataOf(json).map({ stringValue($0["taskId"]) }), !taskId.isEmpty {
            try await waitTask(taskId: taskId, payload: payload)
        }
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let json = try await businessPost(
            url: GuangYaConstants.deleteFileURL,
            body: ["fileIds": ids],
            deviceId: payload.deviceId,
            token: payload.accessToken
        )
        try checkBusiness(json, fallback: "光鸭删除失败")
        if let taskId = dataOf(json).map({ stringValue($0["taskId"]) }), !taskId.isEmpty {
            try await waitTask(taskId: taskId, payload: payload)
        }
    }

    public func createCloudShare(
        files: [ShareFile],
        title: String,
        expire: CloudShareExpire,
        passcode: String?,
        credential: String
    ) async throws -> CloudShareResult {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw ProviderError.missingData("请选择要分享的文件") }
        let cleanPwd = (passcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shareTitle = title.isEmpty ? (files.first?.fname ?? "分享文件") : title
        let body: [String: Any] = [
            "fileIds": ids,
            "title": shareTitle,
            "validateDuration": expire.daysOrNull ?? 0,
            "shareType": cleanPwd.isEmpty ? 0 : 1,
            "code": cleanPwd,
            "autoFillCode": false,
            "trafficLimit": "0",
            "maxRestoreCount": 0,
            "downloadType": 1
        ]
        let json = try await businessPost(
            url: GuangYaConstants.shareFileURL,
            body: body,
            deviceId: payload.deviceId,
            token: payload.accessToken
        )
        try checkBusiness(json, fallback: "光鸭创建分享失败")
        guard let data = dataOf(json) else {
            throw ProviderError.missingData("光鸭未返回分享信息")
        }
        let shareId = stringValue(data["shareId"]).isEmpty ? stringValue(data["id"]) : stringValue(data["shareId"])
        let rawUrl = stringValue(data["shareUrl"])
        let shareUrl = rawUrl.isEmpty ? "\(GuangYaConstants.webSite)/s/\(shareId)" : rawUrl
        guard !shareUrl.isEmpty && shareUrl != "\(GuangYaConstants.webSite)/s/" else {
            throw ProviderError.missingData("光鸭未返回有效分享链接")
        }
        let realCode = stringValue(data["code"]).isEmpty ? cleanPwd : stringValue(data["code"])
        return CloudShareResult(
            platform: .guangya,
            shareUrl: shareUrl,
            passcode: realCode,
            pwdId: shareId,
            title: shareTitle,
            expire: expire
        )
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        return try await fetchPersonalDownload(file: file, payload: payload)
    }

    public func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String? {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        let io = UploadIO(source: source, onProgress: onProgress)
        io.report(.preparing)
        let md5 = try io.digestHex(.md5)
        let body: [String: Any] = [
            "capacity": 2,
            "name": source.fileName,
            "parentId": parentFid,
            "res": [
                "fileSize": source.fileSize,
                "md5": md5
            ]
        ]
        let json = try await businessPost(
            url: GuangYaConstants.uploadTokenURL,
            body: body,
            deviceId: payload.deviceId,
            token: payload.accessToken
        )
        let code = stringValue(json["code"])
        if code != "156" {
            try checkBusiness(json, fallback: "创建光鸭上传任务失败")
        }
        guard let data = dataOf(json) else {
            throw ProviderError.missingData("光鸭未返回上传任务信息")
        }
        let taskId = stringValue(data["taskId"])
        guard !taskId.isEmpty else {
            throw ProviderError.missingData("光鸭上传任务缺少 taskId")
        }
        if code != "156" {
            let creds = data["creds"] as? [String: Any]
            func field(_ key: String) -> String {
                let top = stringValue(data[key])
                return top.isEmpty ? stringValue(creds?[key]) : top
            }
            let endpoint = stringValue(data["fullEndPoint"]).isEmpty ? stringValue(data["endPoint"]) : stringValue(data["fullEndPoint"])
            let ak = field("accessKeyID").isEmpty ? field("accessKeyId") : field("accessKeyID")
            try await io.ossMultipart(
                endpoint: endpoint,
                bucket: stringValue(data["bucketName"]),
                objectKey: stringValue(data["objectPath"]),
                accessKey: ak,
                secretKey: field("secretAccessKey"),
                securityToken: field("sessionToken")
            )
        }
        io.report(.finishing, sent: source.fileSize)
        for _ in 0..<120 {
            let status = try await businessPost(
                url: GuangYaConstants.uploadTaskInfoURL,
                body: ["taskId": taskId],
                deviceId: payload.deviceId,
                token: payload.accessToken
            )
            let fileId = dataOf(status).map { stringValue($0["fileId"]) } ?? ""
            if !fileId.isEmpty {
                return fileId
            }
            let statusCode = stringValue(status["code"])
            if !statusCode.isEmpty && statusCode != "0" && !GuangYaConstants.uploadPendingCodes.contains(statusCode) {
                try checkBusiness(status, fallback: "查询光鸭上传结果失败")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ProviderError.apiMessage("光鸭正在校验文件内容，请稍后刷新目录查看")
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        try await restoreShare(
            shareToken: session.stoken,
            fileIds: [file.fid],
            parentId: toDirFid,
            payload: payload
        )
    }
}
