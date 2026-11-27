//
//  Pan115Provider+CloudDrive.swift
//  YunX
//
//  115 网盘个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension Pan115Provider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard Pan115Constants.hasLoginCookie(credential) else { return nil }
        guard let resp = try? await http.send(
            url: Pan115Constants.indexInfoURL,
            headers: apiHeaders(cookie: credential)
        ),
              let json = try? parseJSON(resp),
              let data = json["data"] as? [String: Any],
              let space = data["space_info"] as? [String: Any] else {
            return nil
        }
        let total = int64Value((space["all_total"] as? [String: Any])?["size"])
        let used = int64Value((space["all_use"] as? [String: Any])?["size"])
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let cid = dirFid.isEmpty ? Pan115Constants.rootCid : dirFid
        return try await listPersonalFiles(cid: cid, cookie: credential)
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let pid = parentFid.isEmpty ? Pan115Constants.rootCid : parentFid
        return try await createFolder(parentCid: pid, name: name, cookie: credential)
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let body = "fid=\(urlEncode(file.fid))&file_name=\(urlEncode(newName))&files_new_name%5B\(urlEncode(file.fid))%5D=\(urlEncode(newName))"
        let resp = try await http.send(
            url: Pan115Constants.fileRenameURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "115 重命名失败")
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let pid = parentFid.isEmpty ? Pan115Constants.rootCid : parentFid
        var pairs = ["pid=\(urlEncode(pid))"]
        for (idx, id) in ids.enumerated() {
            pairs.append("fid%5B\(idx)%5D=\(urlEncode(id))")
        }
        pairs.append("ignore_warn=1")
        let body = pairs.joined(separator: "&")

        var resp = try await http.send(
            url: Pan115Constants.fileDeleteURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: body.data(using: .utf8)
        )
        var json = try parseJSON(resp)
        // errno 800007 需二次确认
        if intValue(json["errno"]) == 800007 {
            resp = try await http.send(
                url: Pan115Constants.fileDeleteURL,
                method: "POST",
                headers: formHeaders(cookie: credential),
                body: body.data(using: .utf8)
            )
            json = try parseJSON(resp)
        }
        try checkState(json, fallback: "115 删除失败")
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let pickcode = file.fidToken
        guard !pickcode.isEmpty else {
            throw ProviderError.missingData("115 文件缺少 pickcode，请刷新目录后重试")
        }
        await refreshClientVersionIfNeeded()

        // 优先电脑端加密通道（无大小限制）
        if let appLink = try? await fetchAppDownloadLink(pickcode: pickcode, cookie: credential, fallbackFile: file) {
            return appLink
        }

        // 兜底网页端接口（仅小文件）
        let url = "\(Pan115Constants.fileDownloadURL)?pickcode=\(urlEncode(pickcode))"
        var headers = apiHeaders(cookie: credential)
        headers["User-Agent"] = Pan115Constants.clientUA
        headers["Referer"] = Pan115Constants.downloadReferer
        let resp = try await http.send(url: url, headers: headers)
        let json = try parseJSON(resp)
        try checkState(json, fallback: "获取 115 个人盘直链失败")
        guard let data = json["data"] as? [String: Any],
              let dlUrl = data["file_url"] as? String, !dlUrl.isEmpty else {
            throw ProviderError.missingData("115 未返回有效下载地址")
        }
        let name = (data["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file.fname
        let size = int64Value(data["file_size"]) > 0 ? int64Value(data["file_size"]) : file.fsize
        return DownloadLink(
            fid: file.fid,
            filename: name,
            downloadUrl: dlUrl,
            size: size,
            guestCookie: resp.extractPathBoundCookie()
        )
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let (receiveCode, _) = Pan115Constants.decodeShareToken(session.stoken)
        let targetCid = toDirFid.isEmpty ? Pan115Constants.rootCid : toDirFid
        try await receiveShare(
            shareCode: session.shareId,
            receiveCode: receiveCode,
            fileId: file.fid,
            targetCid: targetCid,
            cookie: credential
        )
    }
}
