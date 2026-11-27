//
//  C139Provider+CloudDrive.swift
//  YunX
//
//  139 云盘（和彩云）个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension C139Provider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard let authorization = C139Constants.extractAuthorization(credential),
              let account = C139Constants.accountFromAuthorization(authorization) else {
            return nil
        }
        let req: [String: Any] = [
            "userDomainId": "",
            "commonAccountInfo": ["account": account, "accountType": 1]
        ]
        guard let plain = try? compactJSONString(req),
              let json = try? await cloudPost(
                url: C139Constants.quotaDetailURL,
                plainBody: plain,
                authorization: authorization,
                cookie: credential,
                needSkey: true
              ),
              let data = json["data"] as? [String: Any] else {
            return nil
        }
        let total = int64Value(data["diskSize"]) * 1024 * 1024
        let free = int64Value(data["freeDiskSize"]) * 1024 * 1024
        let usedFromList = (data["quotaList"] as? [[String: Any]])?.first.map { int64Value($0["usedSize"]) * 1024 * 1024 }
        let used = usedFromList ?? max(0, total - free)
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.apiMessage("139 个人网盘需要含 authorization 的登录凭证，请在「账号」页重新登录")
        }
        let parent = dirFid.isEmpty ? "/" : dirFid
        let thumbHeaders = [
            "User-Agent": C139Constants.pcUA,
            "Referer": "https://yun.139.com/"
        ]

        var all: [ShareFile] = []
        var seen = Set<String>()
        var cursor: String? = nil

        for _ in 0..<100 {
            let cursorVal: Any = (cursor?.isEmpty == false && cursor != "null") ? cursor! : NSNull()
            let req: [String: Any] = [
                "pageInfo": ["pageSize": 100, "pageCursor": cursorVal],
                "orderBy": "updated_at",
                "orderDirection": "DESC",
                "parentFileId": parent,
                "imageThumbnailStyleList": ["Small", "Large"]
            ]
            let plain = try compactJSONString(req)
            let json = try await cloudPost(url: C139Constants.fileListURL, plainBody: plain, authorization: authorization)
            try checkCloud(json, fallback: "获取 139 个人盘列表失败")
            guard let data = json["data"] as? [String: Any] else { break }
            let items = data["items"] as? [[String: Any]] ?? []
            for item in items {
                let fid = stringValue(item["fileId"])
                guard !fid.isEmpty, seen.insert(fid).inserted else { continue }
                let isDir = stringValue(item["type"]) == "folder"
                let thumb = Self.extractThumbnail(from: item, headers: thumbHeaders)
                all.append(ShareFile(
                    fid: fid,
                    fname: stringValue(item["name"]),
                    fsize: isDir ? 0 : int64Value(item["size"]),
                    isdir: isDir,
                    pdirFid: parent,
                    fidToken: fid,
                    modifyTime: stringValue(item["updatedAt"]),
                    thumbnail: thumb
                ))
            }
            let rawNext = data["nextPageCursor"]
            if rawNext == nil || rawNext is NSNull { break }
            let nextStr = stringValue(rawNext)
            if nextStr.isEmpty || nextStr == "null" || nextStr == cursor { break }
            cursor = nextStr
        }
        return all
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        let parent = parentFid.isEmpty ? "/" : parentFid
        let req: [String: Any] = [
            "parentFileId": parent,
            "name": name,
            "description": "",
            "type": "folder",
            "fileRenameMode": "force_rename"
        ]
        let json = try await cloudPost(url: C139Constants.fileCreateURL, plainBody: try compactJSONString(req), authorization: authorization)
        try checkCloud(json, fallback: "创建 139 文件夹失败")
        let fid = stringValue((json["data"] as? [String: Any])?["fileId"])
        guard !fid.isEmpty else { throw ProviderError.missingData("创建 139 文件夹未返回目录 ID") }
        return fid
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        let req: [String: Any] = [
            "fileId": file.fid,
            "name": newName,
            "description": ""
        ]
        let json = try await cloudPost(url: C139Constants.fileUpdateURL, plainBody: try compactJSONString(req), authorization: authorization)
        try checkCloud(json, fallback: "139 重命名失败")
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let req: [String: Any] = ["fileIds": ids]
        let json = try await cloudPost(url: C139Constants.batchTrashURL, plainBody: try compactJSONString(req), authorization: authorization)
        try checkCloud(json, fallback: "139 删除失败")
    }

    public func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let targetDir = toDirFid.isEmpty ? "/" : toDirFid
        let req: [String: Any] = [
            "fileIds": ids,
            "toParentFileId": targetDir
        ]
        let json = try await cloudPost(
            url: C139Constants.batchMoveURL,
            plainBody: try compactJSONString(req),
            authorization: authorization
        )
        try checkCloud(json, fallback: "139 移动失败")

        let taskId = stringValue((json["data"] as? [String: Any])?["taskId"])
        guard !taskId.isEmpty else { return }
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let tJson = try? await cloudPost(
                url: C139Constants.taskGetURL,
                plainBody: try compactJSONString(["taskId": taskId]),
                authorization: authorization
            ), let tData = tJson["data"] as? [String: Any],
               let info = tData["taskInfo"] as? [String: Any] else {
                break
            }
            let status = stringValue(info["status"]).lowercased()
            let progress = int64Value(info["progress"])
            if progress >= 100 || status == "succeed" || status == "success" || status == "finished" || status == "failed" {
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
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        guard let account = C139Constants.accountFromAuthorization(authorization) else {
            throw ProviderError.apiMessage("139 账号信息解析失败，请重新登录")
        }
        let coIDLst = files.filter { !$0.isdir }.map(\.fid).filter { !$0.isEmpty }
        let caIDLst = files.filter { $0.isdir }.map(\.fid).filter { !$0.isEmpty }
        guard !coIDLst.isEmpty || !caIDLst.isEmpty else {
            throw ProviderError.missingData("请选择要分享的文件")
        }
        let dedicatedName = title.isEmpty ? (files.first?.fname ?? "分享文件") : title
        var getOutLinkReq: [String: Any] = [
            "subLinkType": 0,
            "encrypt": 1,
            "coIDLst": coIDLst,
            "caIDLst": caIDLst,
            "pubType": 1,
            "dedicatedName": dedicatedName,
            "periodUnit": 1,
            "viewerLst": [],
            "extInfo": ["isWatermark": 0, "shareChannel": "3001"],
            "commonAccountInfo": ["account": account, "accountType": 1]
        ]
        if let days = expire.daysOrNull {
            getOutLinkReq["period"] = days
        }
        let plain = try compactJSONString(["getOutLinkReq": getOutLinkReq])
        let resp = try await cloudPost(
            url: C139Constants.outlinkCreateURL,
            plainBody: plain,
            authorization: authorization,
            cookie: credential,
            needSkey: true
        )
        let success = (resp["success"] as? Bool) ?? true
        let code = stringValue(resp["code"])
        guard success && code == "0" else {
            let msg = stringValue(resp["message"])
            throw ProviderError.apiMessage(msg.isEmpty ? "139 创建分享失败（\(code)）" : msg)
        }
        guard let data = resp["data"] as? [String: Any],
              let outRes = data["getOutLinkRes"] as? [String: Any],
              let setArr = outRes["getOutLinkResSet"] as? [[String: Any]],
              let first = setArr.first else {
            throw ProviderError.missingData("139 未返回分享链接")
        }
        let linkUrl = stringValue(first["linkUrl"])
        guard !linkUrl.isEmpty else { throw ProviderError.missingData("139 未返回分享链接") }
        return CloudShareResult(
            platform: .c139,
            shareUrl: linkUrl,
            passcode: stringValue(first["passwd"]),
            pwdId: stringValue(first["linkID"]),
            title: dedicatedName,
            expire: expire
        )
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        let req: [String: Any] = ["fileId": file.fid]
        let json = try await cloudPost(url: C139Constants.downloadURL, plainBody: try compactJSONString(req), authorization: authorization)
        try checkCloud(json, fallback: "获取 139 个人盘直链失败")
        guard let data = json["data"] as? [String: Any],
              let url = data["url"] as? String, !url.isEmpty else {
            throw ProviderError.missingData("139 未返回有效下载地址")
        }
        let name = stringValue(data["name"]).isEmpty ? file.fname : stringValue(data["name"])
        let size = int64Value(data["size"]) > 0 ? int64Value(data["size"]) : file.fsize
        return DownloadLink(fid: file.fid, filename: name, downloadUrl: url, size: size)
    }

    public func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String? {
        guard let authorization = C139Constants.extractAuthorization(credential) else {
            throw ProviderError.loginRequired(.c139)
        }
        let io = UploadIO(source: source, onProgress: onProgress)
        io.report(.preparing)
        let hash = try io.digestHex(.sha256)
        let partSize: Int64 = source.fileSize > 30 * 1024 * 1024 * 1024 ? 512 * 1024 * 1024 : 100 * 1024 * 1024
        let count = max(1, (source.fileSize + partSize - 1) / partSize)
        let partSpecs: [[String: Any]] = (0..<count).map { idx in
            [
                "partNumber": Int(idx + 1),
                "partSize": min(source.fileSize - idx * partSize, partSize),
                "parallelHashCtx": ["partOffset": idx * partSize]
            ]
        }
        let targetDir = parentFid.isEmpty ? "/" : parentFid
        let createReq: [String: Any] = [
            "contentHash": hash,
            "contentHashAlgorithm": "SHA256",
            "contentType": "application/octet-stream",
            "parallelUpload": false,
            "partInfos": Array(partSpecs.prefix(100)),
            "size": source.fileSize,
            "parentFileId": targetDir,
            "name": source.fileName,
            "type": "file",
            "fileRenameMode": "auto_rename"
        ]
        let created = try await cloudPost(
            url: C139Constants.fileCreateURL,
            plainBody: try compactJSONString(createReq),
            authorization: authorization
        )
        try checkCloud(created, fallback: "创建 139 上传任务失败")
        guard let cData = created["data"] as? [String: Any] else {
            throw ProviderError.missingData("139 未返回上传任务信息")
        }
        if (cData["exist"] as? Bool) == true {
            throw ProviderError.apiMessage("当前目录已存在同名文件")
        }
        let fileId = stringValue(cData["fileId"])
        guard !fileId.isEmpty else {
            throw ProviderError.missingData("139 未返回文件 ID")
        }
        if (cData["rapidUpload"] as? Bool) == true {
            io.report(.finishing, sent: source.fileSize)
            return fileId
        }
        let uploadId = stringValue(cData["uploadId"])
        guard !uploadId.isEmpty else {
            throw ProviderError.missingData("139 上传任务缺少 uploadId")
        }

        var batch = cData
        var first = 0
        while first < Int(count) {
            if first > 0 {
                let batchEnd = min(first + 100, partSpecs.count)
                let req: [String: Any] = [
                    "fileId": fileId,
                    "uploadId": uploadId,
                    "partInfos": Array(partSpecs[first..<batchEnd])
                ]
                let resp = try await cloudPost(
                    url: C139Constants.fileUploadURLURL,
                    plainBody: try compactJSONString(req),
                    authorization: authorization
                )
                try checkCloud(resp, fallback: "获取 139 上传分片地址失败")
                guard let bData = resp["data"] as? [String: Any] else {
                    throw ProviderError.missingData("139 未返回分片地址")
                }
                batch = bData
            }
            guard let addresses = batch["partInfos"] as? [[String: Any]], !addresses.isEmpty else {
                throw ProviderError.missingData("139 分片上传地址不完整")
            }
            for (offsetIdx, part) in addresses.enumerated() {
                let partIdx = Int(int64Value(part["partNumber"])) - 1
                guard partIdx == first + offsetIdx else {
                    throw ProviderError.apiMessage("139 分片编号不匹配")
                }
                let uploadUrl = stringValue(part["uploadUrl"])
                guard !uploadUrl.isEmpty else {
                    throw ProviderError.missingData("139 分片缺少 uploadUrl")
                }
                let start = Int64(partIdx) * partSize
                let resp = try await io.send(
                    url: uploadUrl,
                    method: "PUT",
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Origin": "https://yun.139.com",
                        "Referer": "https://yun.139.com/"
                    ],
                    contentType: "application/octet-stream",
                    start: start,
                    end: min(source.fileSize, start + partSize),
                    retries: 1
                )
                guard resp.isSuccessful else {
                    throw ProviderError.apiMessage("139 分片上传失败（HTTP \(resp.statusCode)）")
                }
            }
            first += addresses.count
        }
        io.report(.finishing, sent: source.fileSize)
        let completeReq: [String: Any] = [
            "contentHash": hash,
            "contentHashAlgorithm": "SHA256",
            "fileId": fileId,
            "uploadId": uploadId
        ]
        let completed = try await cloudPost(
            url: C139Constants.fileUploadCompleteURL,
            plainBody: try compactJSONString(completeReq),
            authorization: authorization
        )
        try checkCloud(completed, fallback: "139 合并上传失败")
        return fileId
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        let authorization = C139Constants.extractAuthorization(credential)
        let account = C139Constants.extractAccountFull(credential)
            ?? authorization.flatMap(C139Constants.accountFromAuthorization)
            ?? ""
        guard !account.isEmpty else {
            throw ProviderError.loginRequired(.c139)
        }
        let targetDir = toDirFid.isEmpty ? "/" : toDirFid
        let contentList = file.isdir ? [] : ["/\(file.fid)"]
        let catalogList = file.isdir ? [file.fid] : []
        let taskInfo: [String: Any] = [
            "contentInfoList": contentList,
            "catalogInfoList": catalogList,
            "newCatalogID": targetDir,
            "linkID": session.shareId,
            "newCatalogName": "",
            "needPassword": !session.stoken.isEmpty
        ]
        let req: [String: Any] = [
            "createOuterLinkBatchOprTaskReq": [
                "msisdn": account,
                "ownerAccount": "",
                "taskType": 1,
                "taskInfo": taskInfo,
                "linkID": session.shareId,
                "needPassword": !session.stoken.isEmpty
            ],
            "commonAccountInfo": ["account": account, "accountType": 1]
        ]
        let resp = try await sharePostEncrypted(
            url: C139Constants.transferCreateURL,
            plainBody: try compactJSONString(req),
            authorization: authorization
        )
        let code = stringValue(resp["resultCode"]).isEmpty ? stringValue(resp["code"]) : stringValue(resp["resultCode"])
        if !code.isEmpty && code != "0" {
            let desc = stringValue(resp["desc"])
            throw ProviderError.apiMessage(desc.isEmpty ? "139 转存失败（\(code)）" : desc)
        }
    }

    // MARK: - 139 个人盘明文网关 POST（全套 APISIX 渠道头）

    private func cloudPost(
        url: String,
        plainBody: String,
        authorization: String,
        cookie: String? = nil,
        needSkey: Bool = false
    ) async throws -> [String: Any] {
        var headers: [String: String] = [
            "Authorization": authorization,
            "mcloud-sign": C139Crypto.signHeader(bodyJson: plainBody),
            "x-yun-channel-source": C139Constants.yunChannelSource,
            "x-yun-app-channel": C139Constants.yunChannelSource,
            "x-huawei-channelSrc": C139Constants.yunChannelSource,
            "mcloud-version": C139Constants.mcloudVersion,
            "mcloud-client": C139Constants.mcloudClient,
            "mcloud-channel": C139Constants.mcloudChannel,
            "mcloud-route": "001",
            "x-yun-module-type": C139Constants.yunModuleType,
            "x-yun-api-version": "v1",
            "x-yun-svc-type": "1",
            "x-SvcType": "1",
            "caller": "web",
            "x-inner-ntwk": "2",
            "CMS-DEVICE": "default",
            "x-m4c-src": C139Constants.m4cSrc,
            "x-m4c-caller": C139Constants.m4cCaller,
            "X-Deviceinfo": C139Constants.xDeviceInfo,
            "x-yun-client-info": C139Constants.xClientInfo,
            "INNER-HCY-ROUTER-HTTPS": "1",
            "Sec-Fetch-Site": "same-site",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "X-Requested-With": "mark.via",
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": C139Constants.pcUA,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*"
        ]
        if let cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
            if needSkey, let skey = C139Constants.cookieValue(cookie, name: "skey") {
                headers["mcloud-skey"] = skey
            }
        }
        let resp = try await http.send(url: url, method: "POST", headers: headers, body: plainBody.data(using: .utf8))
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        return json
    }

    private func checkCloud(_ json: [String: Any], fallback: String) throws {
        let code = stringValue(json["code"])
        let success = (json["success"] as? Bool) ?? true
        if success && (code == "0000" || code == "0") { return }
        let msg = stringValue(json["message"])
        throw ProviderError.apiMessage(msg.isEmpty ? "\(fallback)（错误码 \(code)）" : msg)
    }

    private static func extractThumbnail(from item: [String: Any], headers: [String: String]) -> FileThumbnail? {
        if let arr = item["thumbnailUrls"] as? [[String: Any]] {
            var first: FileThumbnail?
            for entry in arr {
                guard let url = entry["url"] as? String,
                      let thumb = FileThumbnail.secure(url: url, headers: headers) else { continue }
                if first == nil { first = thumb }
                if (entry["style"] as? String)?.lowercased() == "large" { return thumb }
            }
            if let first { return first }
        }
        for key in ["bigthumbnailURL", "midthumbnailURL", "thumbnailURL"] {
            if let url = item[key] as? String,
               let thumb = FileThumbnail.secure(url: url, headers: headers) {
                return thumb
            }
        }
        return nil
    }
}
