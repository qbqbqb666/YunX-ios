//
//  GuangYaProvider+CloudDrive.swift
//  YunX
//
//  光鸭云盘个人空间管理与分享转存实现（独立分区文件）。
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

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }
        return try await fetchPersonalDownload(file: file, payload: payload)
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
