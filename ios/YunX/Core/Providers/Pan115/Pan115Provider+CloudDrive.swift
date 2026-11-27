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

    public func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let pid = toDirFid.isEmpty ? Pan115Constants.rootCid : toDirFid
        var pairs = ["pid=\(urlEncode(pid))"]
        for (idx, id) in ids.enumerated() {
            pairs.append("fid%5B\(idx)%5D=\(urlEncode(id))")
        }
        let resp = try await http.send(
            url: Pan115Constants.fileMoveURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: pairs.joined(separator: "&").data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "115 移动失败")

        let topMoveId = json["move_proid"] as? String ?? ""
        let dataMoveId = (json["data"] as? [String: Any])?["move_proid"] as? String ?? ""
        let moveId = topMoveId.isEmpty ? dataMoveId : topMoveId
        guard !moveId.isEmpty else { return }

        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 400_000_000)
            guard let pResp = try? await http.send(
                url: "\(Pan115Constants.moveProgressURL)?move_proid=\(urlEncode(moveId))",
                headers: apiHeaders(cookie: credential)
            ),
                  let pJson = try? parseJSON(pResp),
                  (pJson["state"] as? Bool) == true,
                  let pData = pJson["data"] as? [String: Any] else {
                break
            }
            let percent = (pData["percent"] as? NSNumber)?.doubleValue ?? 0
            let count = (pData["count"] as? NSNumber)?.intValue ?? 0
            if percent >= 100.0 || count <= 0 {
                break
            }
        }
    }

    public func createCloudShare(
        files: [ShareFile],
        title: String,
        expire: CloudShareExpire,
        passcode: String?,
        credential: String
    ) async throws -> CloudShareResult {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        guard let userId = Pan115Constants.extractUserId(credential) else {
            throw ProviderError.apiMessage("115 Cookie 缺少 UID，无法创建分享")
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw ProviderError.missingData("请选择要分享的文件") }

        // 首次分享确认公开分享协议（失败忽略）
        _ = try? await http.send(
            url: Pan115Constants.allowProtocolURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: "action=pubshare".data(using: .utf8)
        )

        let idText = ids.joined(separator: ",")
        // 预检（ignore_warn=0），失败不阻断真正创建
        _ = try? await http.send(
            url: Pan115Constants.shareSendURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: "user_id=\(urlEncode(userId))&file_ids=\(urlEncode(idText))&ignore_warn=0".data(using: .utf8)
        )

        let resp = try await http.send(
            url: Pan115Constants.shareSendURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: "user_id=\(urlEncode(userId))&file_ids=\(urlEncode(idText))&ignore_warn=1".data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "115 创建分享失败")

        let data = json["data"] as? [String: Any] ?? [:]
        func field(_ key: String) -> String {
            if let v = data[key] as? String, !v.isEmpty { return v }
            if let v = json[key] as? String, !v.isEmpty { return v }
            return ""
        }
        let shareCode = field("share_code")
        guard !shareCode.isEmpty else { throw ProviderError.missingData("115 未返回分享码") }

        // 115 有效期需在创建后通过 updateshare 二次设置，失败保留已创建分享并附带告警
        let duration = expire.pan115Duration
        var applied = false
        var warning: String?
        if let uResp = try? await http.send(
            url: Pan115Constants.shareUpdateURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: "share_code=\(urlEncode(shareCode))&share_duration=\(urlEncode(duration))".data(using: .utf8)
        ), let uJson = try? parseJSON(uResp) {
            if (uJson["state"] as? Bool) == true {
                applied = true
            } else {
                let reason = (uJson["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (uJson["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "未知原因"
                warning = "分享已创建，但有效期修改失败（\(reason)），当前仍为平台默认期限"
            }
        } else {
            warning = "分享已创建，但有效期修改请求失败，当前仍为平台默认期限"
        }

        let finalExpire = applied ? expire : CloudShareExpire.fromPan115Duration(field("share_ex_duration"))
        let shareUrl = field("share_url").isEmpty ? "\(Pan115Constants.shareHost)/s/\(shareCode)" : field("share_url")
        let receiveCode = field("receive_code").isEmpty ? field("sys_receive_code") : field("receive_code")
        return CloudShareResult(
            platform: .pan115,
            shareUrl: shareUrl,
            passcode: receiveCode,
            pwdId: shareCode,
            title: field("share_title").isEmpty ? title : field("share_title"),
            expire: finalExpire,
            warning: warning
        )
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

    public func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String? {
        guard Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        guard source.fileSize <= Pan115Constants.uploadMaxSize else {
            throw ProviderError.apiMessage("115 单文件直传上限为 5 GB")
        }
        let io = UploadIO(source: source, onProgress: onProgress)
        io.report(.preparing)
        let pid = parentFid.isEmpty ? Pan115Constants.rootCid : parentFid
        let initBody = "filename=\(urlEncode(source.fileName))&filesize=\(source.fileSize)&target=\(urlEncode("U_1_\(pid)"))&path="
        let initResp = try await http.send(
            url: Pan115Constants.uploadInitURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: initBody.data(using: .utf8)
        )
        let initJson = try parseJSON(initResp)
        if initJson["state"] != nil {
            try checkState(initJson, fallback: "获取 115 上传凭据失败")
        }
        let hostStr = initJson["host"] as? String ?? ""
        let objectKey = initJson["object"] as? String ?? ""
        let policy = initJson["policy"] as? String ?? ""
        let accessId = initJson["accessid"] as? String ?? ""
        let signature = initJson["signature"] as? String ?? ""
        let callback = initJson["callback"] as? String ?? ""
        guard let parsedHost = URL(string: hostStr),
              let hostName = parsedHost.host,
              hostName.hasSuffix(".aliyuncs.com") else {
            throw ProviderError.apiMessage("115 返回了非官方 OSS 上传节点")
        }
        guard !objectKey.isEmpty, !policy.isEmpty, !accessId.isEmpty, !signature.isEmpty, !callback.isEmpty else {
            throw ProviderError.missingData("115 上传策略参数不完整")
        }
        let targetURL = "https://\(hostName)\(parsedHost.path)"
        let response = try await io.send(
            url: targetURL,
            method: "POST",
            headers: ["User-Agent": Pan115Constants.webUA],
            fields: [
                ("name", source.fileName),
                ("key", objectKey),
                ("policy", policy),
                ("OSSAccessKeyId", accessId),
                ("success_action_status", "200"),
                ("callback", callback),
                ("signature", signature)
            ],
            retries: 0
        )
        guard response.isSuccessful else {
            throw ProviderError.apiMessage("115 上传失败（HTTP \(response.statusCode)）")
        }
        io.report(.finishing, sent: source.fileSize)
        if let json = response.jsonObject() {
            if let state = json["state"] as? Bool, !state {
                let err = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "115 上传落库失败"
                throw ProviderError.apiMessage(err)
            }
            if let fid = (json["data"] as? [String: Any])?["file_id"] as? String, !fid.isEmpty {
                return fid
            }
            if let fid = json["file_id"] as? String, !fid.isEmpty {
                return fid
            }
        }
        return nil
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
