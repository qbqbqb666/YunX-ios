//
//  UCProvider+CloudDrive.swift
//  YunX
//
//  UC 网盘个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension UCProvider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard !credential.isEmpty else { return nil }
        let headers = [
            "Cookie": credential,
            "User-Agent": UCConstants.cloudUA,
            "Origin": UCConstants.webOrigin,
            "Referer": UCConstants.downloadReferer
        ]
        guard let resp = try? await http.send(url: UCConstants.memberURL, headers: headers),
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let data = json["data"] as? [String: Any] else {
            return nil
        }
        let used = (data["use_capacity"] as? NSNumber)?.int64Value ?? 0
        let total = (data["total_capacity"] as? NSNumber)?.int64Value ?? 0
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.uc) }
        let freshCookie = await refreshSession(cookie: credential)
        let pdir = dirFid.isEmpty ? UCConstants.defaultPdirFid : dirFid
        let thumbHeaders = [
            "User-Agent": UCConstants.cloudUA,
            "Referer": UCConstants.downloadReferer,
            "Origin": UCConstants.webOrigin
        ]
        let thumbAuthHeaders = [
            "Cookie": freshCookie,
            "User-Agent": UCConstants.cloudUA,
            "Referer": UCConstants.downloadReferer,
            "Origin": UCConstants.webOrigin
        ]

        var all: [ShareFile] = []
        for page in 1...100 {
            let url = "\(UCConstants.cloudFileSortURL)&pdir_fid=\(pdir)&_page=\(page)&_size=100&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type%3Aasc%2Cupdated_at%3Adesc"
            let headers = [
                "Cookie": freshCookie,
                "User-Agent": UCConstants.cloudUA,
                "Origin": UCConstants.webOrigin,
                "Referer": UCConstants.downloadReferer
            ]
            let resp = try await http.send(url: url, headers: headers)
            let data = try unwrapEnvelope(resp: resp, originalCookie: freshCookie)
            let list = data["list"] as? [[String: Any]] ?? []
            let batch = list.map { item in
                let rawName = (item["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["fname"] as? String) ?? ""
                let thumb = FileThumbnail.hostScoped(
                    url: item["thumbnail"] as? String ?? "",
                    headers: thumbHeaders,
                    authHost: UCConstants.thumbnailHost,
                    authHeaders: thumbAuthHeaders
                )
                return ShareFile(
                    fid: item["fid"] as? String ?? "",
                    fname: rawName,
                    fsize: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    isdir: (item["dir"] as? Bool) ?? false,
                    pdirFid: item["pdir_fid"] as? String ?? pdir,
                    fidToken: "",
                    modifyTime: Self.stringValue(item["updated_at"]),
                    thumbnail: thumb
                )
            }
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.uc) }
        let pdir = parentFid.isEmpty ? UCConstants.defaultPdirFid : parentFid
        let body: [String: Any] = [
            "pdir_fid": pdir,
            "file_name": name,
            "dir_path": "",
            "dir_init_lock": false
        ]
        let resp = try await http.send(
            url: UCConstants.fileURL,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": UCConstants.userAgent,
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let data = try unwrapEnvelope(resp: resp, originalCookie: credential)
        guard let fid = data["fid"] as? String, !fid.isEmpty else {
            throw ProviderError.missingData("创建 UC 文件夹失败")
        }
        return fid
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.uc) }
        let body: [String: Any] = [
            "fid": file.fid,
            "file_name": newName
        ]
        let resp = try await http.send(
            url: UCConstants.renameURL,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": UCConstants.userAgent,
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              (json["status"] as? NSNumber)?.intValue == 200 else {
            throw ProviderError.apiMessage("UC 重命名失败")
        }
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.uc) }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let body: [String: Any] = [
            "action_type": 2,
            "filelist": ids,
            "exclude_fids": []
        ]
        let resp = try await http.send(
            url: UCConstants.deleteURL,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": UCConstants.userAgent,
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        _ = try unwrapEnvelope(resp: resp, originalCookie: credential)
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.uc) }
        let freshCookie = await refreshSession(cookie: credential)
        let body: [String: Any] = ["fids": [file.fid]]
        let resp = try await http.send(
            url: UCConstants.cloudDownloadURL,
            method: "POST",
            headers: [
                "Cookie": freshCookie,
                "User-Agent": UCConstants.cloudUA,
                "Origin": UCConstants.webOrigin,
                "Referer": UCConstants.downloadReferer,
                "Content-Type": "application/json;charset=UTF-8"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        let status = (json["status"] as? NSNumber)?.intValue ?? 0
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        guard status == 200 || code == 0 else {
            throw ProviderError.apiMessage((json["message"] as? String) ?? "获取 UC 个人盘直链失败", code: code)
        }
        guard let list = json["data"] as? [[String: Any]], let first = list.first,
              let url = first["download_url"] as? String, !url.isEmpty else {
            throw ProviderError.missingData("UC 未返回有效下载直链")
        }
        let name = (first["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? file.fname
        let size = (first["size"] as? NSNumber)?.int64Value ?? file.fsize
        return DownloadLink(fid: file.fid, filename: name, downloadUrl: url, size: size)
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.uc) }
        let freshCookie = await refreshSession(cookie: credential)
        let targetDir = toDirFid.isEmpty ? UCConstants.defaultPdirFid : toDirFid
        let body: [String: Any] = [
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "pdir_fid": file.pdirFid,
            "to_pdir_fid": targetDir,
            "fid_list": [file.fid],
            "fid_token_list": [file.fidToken],
            "scene": "link"
        ]
        let resp = try await http.send(
            url: UCConstants.saveURL,
            method: "POST",
            headers: [
                "Cookie": freshCookie,
                "User-Agent": UCConstants.userAgent,
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let data = try unwrapEnvelope(resp: resp, originalCookie: freshCookie)
        guard let taskId = data["task_id"] as? String, !taskId.isEmpty else {
            throw ProviderError.missingData("UC 转存任务创建失败")
        }
        let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId
        let pollURL = "\(UCConstants.taskURL)&task_id=\(encoded)&retry_index=0"
        for _ in 0..<12 {
            if let pollResp = try? await http.send(
                url: pollURL,
                headers: ["Cookie": freshCookie, "User-Agent": UCConstants.userAgent]
            ),
               let pJson = try? JSONSerialization.jsonObject(with: pollResp.body) as? [String: Any],
               (pJson["status"] as? NSNumber)?.intValue == 200,
               let pData = pJson["data"] as? [String: Any] {
                let finishedAt = (pData["finished_at"] as? NSNumber)?.int64Value ?? 0
                let status = (pData["status"] as? NSNumber)?.intValue ?? 0
                let taskStatus = (pData["task_status"] as? NSNumber)?.intValue ?? 0
                if finishedAt > 0 || status == 2 || taskStatus == 2 {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
