//
//  Pan123Provider+CloudDrive.swift
//  YunX
//
//  123 云盘个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension Pan123Provider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard !credential.isEmpty else { return nil }
        guard let json = try? await authGet(url: Pan123Constants.userInfoURL, path: "/b/api/user/info", token: credential),
              (json["code"] as? NSNumber)?.intValue == 0,
              let data = json["data"] as? [String: Any] else {
            return nil
        }
        let used = (data["SpaceUsed"] as? NSNumber)?.int64Value ?? 0
        let total = (data["SpacePermanent"] as? NSNumber)?.int64Value ?? 0
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.pan123) }
        let parent = dirFid.isEmpty ? "0" : dirFid
        var all: [ShareFile] = []
        var next = "0"

        for _ in 0..<100 {
            let url = "\(Pan123Constants.fileListURL)?driveId=0&limit=100&next=\(next)&orderBy=update_time&orderDirection=desc&parentFileId=\(parent)&trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0&event=homeListFile&operateType=1&inDirectSpace=false"
            let json = try await authGet(url: url, path: "/b/api/file/list/new", token: credential)
            try checkCodeZero(json, fallback: "获取 123 个人盘列表失败")
            guard let data = json["data"] as? [String: Any] else { break }
            let batch = parseInfoList(data)
            all.append(contentsOf: batch)
            let cursor = data["Next"] as? String ?? "-1"
            if cursor == "-1" || batch.isEmpty { break }
            next = cursor
        }
        return all
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.pan123) }
        let body: [String: Any] = [
            "driveId": 0,
            "parentFileId": Int64(parentFid) ?? 0,
            "fileName": name,
            "size": 0,
            "type": 1,
            "etag": "",
            "duplicate": 1,
            "NotReuse": true,
            "RequestSource": NSNull()
        ]
        let json = try await authPost(
            url: Pan123Constants.fileUploadRequestURL,
            path: "/b/api/file/upload_request",
            body: body,
            token: credential
        )
        try checkCodeZero(json, fallback: "创建 123 文件夹失败")
        let data = json["data"] as? [String: Any] ?? [:]
        let info = data["Info"] as? [String: Any]
        let candidates = [info?["FileId"], data["FileId"], data["fileId"]]
        for c in candidates {
            let s = (c as? String) ?? (c as? NSNumber)?.stringValue ?? ""
            if !s.isEmpty && s != "0" { return s }
        }
        throw ProviderError.missingData("创建 123 文件夹未返回目录 ID")
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.pan123) }
        let body: [String: Any] = [
            "driveId": 0,
            "fileId": Int64(file.fid) ?? 0,
            "fileName": newName,
            "duplicate": 1,
            "event": "fileRename",
            "operatePlace": "right",
            "RequestSource": NSNull()
        ]
        let json = try await authPost(
            url: Pan123Constants.fileRenameURL,
            path: "/b/api/file/rename",
            body: body,
            token: credential
        )
        try checkCodeZero(json, fallback: "123 云盘重命名失败")
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.pan123) }
        guard !files.isEmpty else { return }
        let list: [[String: Any]] = files.map { f in
            let parts = f.fidToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let s3 = parts.indices.contains(0) ? parts[0] : ""
            let etag = parts.indices.contains(1) ? parts[1] : ""
            return [
                "FileId": Int64(f.fid) ?? 0,
                "FileName": f.fname,
                "Type": f.isdir ? 1 : 0,
                "Size": f.fsize,
                "S3KeyFlag": s3,
                "Etag": etag
            ]
        }
        let body: [String: Any] = [
            "driveId": 0,
            "fileTrashInfoList": list,
            "operation": true,
            "event": "intoRecycle",
            "operatePlace": 1,
            "safeBox": false
        ]
        let json = try await authPost(
            url: Pan123Constants.fileTrashURL,
            path: "/b/api/file/trash",
            body: body,
            token: credential
        )
        try checkCodeZero(json, fallback: "123 云盘删除失败")
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.pan123) }
        let parts = file.fidToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let s3 = parts.indices.contains(0) ? parts[0] : ""
        let etag = parts.indices.contains(1) ? parts[1] : ""

        let body: [String: Any] = [
            "driveId": 0,
            "etag": etag,
            "fileId": Int64(file.fid) ?? 0,
            "s3keyFlag": s3,
            "type": 0,
            "fileName": file.fname,
            "size": file.fsize
        ]
        let json = try await authPost(
            url: Pan123Constants.fileDownloadInfoURL,
            path: "/api/file/download_info",
            body: body,
            token: credential
        )
        try checkCodeZero(json, fallback: "获取 123 个人盘直链失败")
        guard let data = json["data"] as? [String: Any],
              let raw = data["DownloadUrl"] as? String, !raw.isEmpty else {
            throw ProviderError.missingData("123 未返回有效下载地址")
        }
        let decoded = Pan123Signer.decodeDownloadURL(raw) ?? raw
        let realUrl = await followRedirectURL(decoded)
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: realUrl, size: file.fsize)
    }

    /// 123 分享转存（mshare 子域，无需客户端签名）
    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.pan123) }
        let shareId = Self.extractShareId(fromFidToken: file.fidToken)
        guard !shareId.isEmpty else {
            throw ProviderError.missingData("123 分享项缺少 S3KeyFlag（ShareId），无法转存")
        }
        let parts = file.fidToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let s3 = parts.indices.contains(0) ? parts[0] : ""
        let etag = parts.indices.contains(1) ? parts[1] : ""
        let node = parts.indices.contains(2) ? parts[2] : ""
        let fileId = Int64(file.fid) ?? 0
        let parentId = Int64(toDirFid) ?? 0

        let body: [String: Any] = [
            "fileList": [[
                "fileID": fileId,
                "fileId": fileId,
                "size": file.fsize,
                "etag": etag,
                "type": file.isdir ? 1 : 0,
                "parentFileID": parentId,
                "parentFileId": parentId,
                "fileName": file.fname,
                "driveID": 0,
                "driveId": 0,
                "s3keyFlag": s3,
                "S3KeyFlag": s3,
                "StorageNode": node
            ]],
            "shareKey": session.shareId,
            "sharePwd": session.stoken,
            "currentLevel": 1,
            "superAdmin": NSNull()
        ]
        let headers = [
            "Authorization": "Bearer \(credential)",
            "LoginUuid": loginUUID,
            "platform": Pan123Constants.platformWeb,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Pan123Constants.dartUA
        ]
        let resp = try await http.send(
            url: "https://\(shareId).mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save",
            method: "POST",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let json = try parseJSON(resp: resp)
        try checkCodeZero(json, fallback: "123 云盘转存失败")
        guard let data = json["data"] as? [String: Any],
              let taskId = (data["taskID"] as? NSNumber)?.int64Value else {
            return
        }

        let pollHeaders = [
            "Authorization": "Bearer \(credential)",
            "LoginUuid": loginUUID,
            "platform": Pan123Constants.platformWeb,
            "User-Agent": Pan123Constants.dartUA
        ]
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let pollURL = "https://\(shareId).mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save/get?taskID=\(taskId)"
            guard let pollResp = try? await http.send(url: pollURL, headers: pollHeaders),
                  let pJson = try? parseJSON(resp: pollResp) else { continue }
            if (pJson["code"] as? NSNumber)?.intValue != 0 {
                if let msg = pJson["message"] as? String, !msg.isEmpty {
                    throw ProviderError.apiMessage("123 转存失败：\(msg)")
                }
                continue
            }
            if let pData = pJson["data"] as? [String: Any] {
                let status = (pData["status"] as? NSNumber)?.intValue ?? -1
                let state = (pData["state"] as? String ?? "").lowercased()
                let done = (pData["finished"] as? Bool == true)
                    || status == 2 || status == 3
                    || state == "success" || state == "done" || state == "2"
                    || pData["newFileId"] != nil || pData["FileId"] != nil || pData["fileId"] != nil
                if done { return }
            }
        }
    }

    public static func extractShareId(fromFidToken fidToken: String) -> String {
        let s3 = fidToken.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
        return s3.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
    }
}
