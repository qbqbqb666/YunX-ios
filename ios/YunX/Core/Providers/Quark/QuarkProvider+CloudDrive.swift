//
//  QuarkProvider+CloudDrive.swift
//  YunX
//
//  夸克网盘个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension QuarkProvider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard !credential.isEmpty else { return nil }
        let headers = [
            "Cookie": credential,
            "User-Agent": QuarkConstants.apiUserAgent
        ]
        guard let data = try? await getJSONData(url: QuarkConstants.memberURL, headers: headers, originalCookie: credential) else {
            return nil
        }
        let used = (data["use_capacity"] as? NSNumber)?.int64Value ?? 0
        let total = (data["total_capacity"] as? NSNumber)?.int64Value ?? 0
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let pdir = dirFid.isEmpty ? QuarkConstants.defaultPdirFid : dirFid
        let thumbHeaders = [
            "User-Agent": QuarkConstants.apiUserAgent,
            "Referer": QuarkConstants.downloadReferer
        ]
        let thumbAuthHeaders = [
            "Cookie": freshCookie,
            "User-Agent": QuarkConstants.apiUserAgent,
            "Referer": QuarkConstants.downloadReferer
        ]

        var all: [ShareFile] = []
        for page in 1...100 {
            let url = "\(QuarkConstants.cloudFileSortURL)&uc_param_str=&pdir_fid=\(pdir)&_page=\(page)&_size=100&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc&fetch_all_file=1&fetch_risk_file_name=1"
            let headers = [
                "Cookie": freshCookie,
                "User-Agent": QuarkConstants.apiUserAgent,
                "Origin": "https://pan.quark.cn",
                "Referer": QuarkConstants.downloadReferer
            ]
            let data = try await getJSONData(url: url, headers: headers, originalCookie: freshCookie)
            let list = data["list"] as? [[String: Any]] ?? []
            let batch = list.map { item in
                let rawName = (item["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["fname"] as? String) ?? ""
                let thumb = FileThumbnail.hostScoped(
                    url: item["thumbnail"] as? String ?? "",
                    headers: thumbHeaders,
                    authHost: QuarkConstants.thumbnailHost,
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
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let pdir = parentFid.isEmpty ? QuarkConstants.defaultPdirFid : parentFid
        return try await createFolder(name: name, parentFid: pdir, cookie: credential)
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let body: [String: Any] = [
            "fid": file.fid,
            "file_name": newName
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let resp = try await http.send(
            url: QuarkConstants.renameURL,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": QuarkConstants.apiUserAgent,
                "Content-Type": "application/json"
            ],
            body: bodyData
        )
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              (json["status"] as? NSNumber)?.intValue == 200 else {
            throw ProviderError.apiMessage("夸克重命名失败")
        }
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let payload: [String: Any] = [
            "action_type": 2,
            "filelist": ids,
            "exclude_fids": []
        ]
        _ = try await postJSONData(url: QuarkConstants.deleteURL, cookie: credential, body: payload)
    }

    public func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let freshCookie = await refreshSession(cookie: credential)
        let targetDir = toDirFid.isEmpty ? QuarkConstants.defaultPdirFid : toDirFid
        let payload: [String: Any] = [
            "action_type": 1,
            "to_pdir_fid": targetDir,
            "filelist": ids,
            "exclude_fids": []
        ]
        let data = try await postJSONData(url: QuarkConstants.moveURL, cookie: freshCookie, body: payload)
        if let taskId = data["task_id"] as? String, !taskId.isEmpty {
            _ = try await pollQuarkCloudTask(taskId: taskId, cookie: freshCookie)
        }
    }

    public func createCloudShare(
        files: [ShareFile],
        title: String,
        expire: CloudShareExpire,
        passcode: String?,
        credential: String
    ) async throws -> CloudShareResult {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw ProviderError.missingData("请选择要分享的文件") }
        let freshCookie = await refreshSession(cookie: credential)
        let cleanPwd = (passcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "fid_list": ids,
            "title": title.isEmpty ? (files.first?.fname ?? "分享文件") : title,
            "url_type": cleanPwd.isEmpty ? 1 : 2,
            "expired_type": expire.quarkUCExpiredType,
            "support_error_code": ["41060"]
        ]
        if !cleanPwd.isEmpty {
            payload["passcode"] = cleanPwd
        }
        let createData = try await postJSONData(url: QuarkConstants.shareCreateURL, cookie: freshCookie, body: payload)
        guard let taskId = createData["task_id"] as? String, !taskId.isEmpty else {
            throw ProviderError.missingData("夸克分享任务创建失败")
        }
        let taskData = try await pollQuarkCloudTask(taskId: taskId, cookie: freshCookie)
        guard let shareId = taskData["share_id"] as? String, !shareId.isEmpty else {
            throw ProviderError.missingData("夸克分享创建超时，请稍后重试")
        }
        let infoData = try await postJSONData(
            url: QuarkConstants.shareInfoURL,
            cookie: freshCookie,
            body: ["share_id": shareId]
        )
        let shareUrl = infoData["share_url"] as? String ?? ""
        guard !shareUrl.isEmpty else { throw ProviderError.missingData("夸克未返回分享链接") }
        let returnedExpire = (infoData["expired_type"] as? NSNumber).map { CloudShareExpire.fromQuarkUC($0.intValue) } ?? expire
        return CloudShareResult(
            platform: .quark,
            shareUrl: shareUrl,
            passcode: infoData["passcode"] as? String ?? cleanPwd,
            pwdId: infoData["pwd_id"] as? String ?? shareId,
            title: (infoData["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title,
            expire: returnedExpire == .unknown ? expire : returnedExpire
        )
    }

    private func pollQuarkCloudTask(taskId: String, cookie: String) async throws -> [String: Any] {
        let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId
        let url = "\(QuarkConstants.taskURL)&task_id=\(encoded)&retry_index=0"
        for _ in 0..<15 {
            if let data = try? await getJSONData(
                url: url,
                headers: ["Cookie": cookie, "User-Agent": QuarkConstants.apiUserAgent],
                originalCookie: cookie
            ) {
                let finishedAt = (data["finished_at"] as? NSNumber)?.int64Value ?? 0
                let status = (data["status"] as? NSNumber)?.intValue ?? 0
                if finishedAt > 0 || status == 2 {
                    return data
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return [:]
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let link = try await requestDownloadLink(cookie: freshCookie, payload: ["fids": [file.fid]], isGuest: false)
        return link.filename.isEmpty ? link.withFilename(file.fname) : link
    }

    public func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String? {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let targetDir = parentFid.isEmpty ? QuarkConstants.defaultPdirFid : parentFid
        let io = UploadIO(source: source, onProgress: onProgress)
        let helper = QuarkUploadHelper(
            apiBase: QuarkConstants.apiBase,
            product: "ucpro",
            origin: "https://pan.quark.cn",
            userAgent: QuarkConstants.apiUserAgent,
            post: { [weak self] url, body in
                guard let self else { throw CancellationError() }
                let resp = try await self.http.send(
                    url: url,
                    method: "POST",
                    headers: [
                        "Cookie": freshCookie,
                        "User-Agent": QuarkConstants.apiUserAgent,
                        "Origin": "https://pan.quark.cn",
                        "Referer": QuarkConstants.downloadReferer,
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
                    throw ProviderError.apiMessage((json["message"] as? String) ?? "夸克上传接口失败", code: code)
                }
                return json["data"] as? [String: Any] ?? [:]
            }
        )
        return try await helper.upload(io: io, parentFid: targetDir)
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let targetDir = toDirFid.isEmpty ? QuarkConstants.defaultPdirFid : toDirFid
        let taskId = try await saveShareFile(session: session, file: file, toDirFid: targetDir, cookie: freshCookie)
        _ = try await pollTransferTask(taskId: taskId, cookie: freshCookie)
    }
}
