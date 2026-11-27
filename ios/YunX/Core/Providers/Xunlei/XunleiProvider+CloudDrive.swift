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
