//
//  BaiduProvider+CloudDrive.swift
//  YunX
//
//  百度网盘个人空间管理与分享转存实现（App + Web 双通道列目录、转存、重命名、删除、直链）。
//

import Foundation
import CryptoKit

extension BaiduProvider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard BaiduConstants.isValidCookie(credential) else { return nil }
        let url = "https://yun.baidu.com/api/quota?clienttype=0&app_id=\(BaiduConstants.appId)&web=1&channel=chunlei&version=\(Int64(Date().timeIntervalSince1970 * 1000))"
        guard let resp = try? await http.send(
            url: url,
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "X-Requested-With": "XMLHttpRequest",
                "Referer": "https://yun.baidu.com/disk/main"
            ]
        ),
              let json = try? parseJSON(resp),
              intValue(json["errno"], default: -1) == 0 else {
            return nil
        }
        let used = int64Value(json["used"])
        let total = int64Value(json["total"])
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        let dir = dirFid.isEmpty ? "/" : dirFid
        // 优先 App 通道，失败自动回退 Web 通道（两套参数与 UA 严格隔离）
        do {
            return try await fetchPersonalList(dir: dir, cookie: credential, useAppChannel: true)
        } catch {
            return try await fetchPersonalList(dir: dir, cookie: credential, useAppChannel: false)
        }
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        let base = parentFid.isEmpty || parentFid == "/" ? "" : parentFid.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = base.isEmpty ? "/\(name)" : "/\(base)/\(name)"
        let ok = await createDir(path: fullPath, cookie: credential)
        guard ok else {
            throw ProviderError.apiMessage("百度网盘创建文件夹失败")
        }
        return fullPath
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        guard let bdstoken = await getBdstoken(cookie: credential) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败，请检查登录态")
        }
        let path = Self.baiduPath(of: file)
        let listData = try JSONSerialization.data(withJSONObject: [["path": path, "newname": newName]])
        let listJson = String(data: listData, encoding: .utf8) ?? "[]"
        let body = "filelist=\(urlEncode(listJson))"
        let url = "https://yun.baidu.com/api/filemanager?async=0&onnest=fail&opera=rename&bdstoken=\(urlEncode(bdstoken))&clienttype=0&app_id=\(BaiduConstants.appId)&web=1"
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded",
                "Referer": "https://yun.baidu.com/disk/main"
            ],
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "百度网盘重命名失败")
    }

    public func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        guard let bdstoken = await getBdstoken(cookie: credential) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败")
        }
        let dest = toDirFid.isEmpty ? "/" : toDirFid
        let items: [[String: String]] = files.compactMap { file in
            let path = Self.baiduPath(of: file)
            guard !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return ["path": path, "dest": dest, "newname": name.isEmpty ? file.fname : name]
        }
        guard !items.isEmpty else { return }
        let listData = try JSONSerialization.data(withJSONObject: items)
        let listJson = String(data: listData, encoding: .utf8) ?? "[]"
        let body = "filelist=\(urlEncode(listJson))"
        let url = "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=move&bdstoken=\(urlEncode(bdstoken))&clienttype=0&app_id=\(BaiduConstants.appId)&web=1"
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded",
                "Referer": "https://yun.baidu.com/disk/main"
            ],
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "百度网盘移动失败")
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        guard let bdstoken = await getBdstoken(cookie: credential) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败")
        }
        let paths = files.map(Self.baiduPath(of:)).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }
        let listData = try JSONSerialization.data(withJSONObject: paths)
        let listJson = String(data: listData, encoding: .utf8) ?? "[]"
        let body = "filelist=\(urlEncode(listJson))"
        let url = "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=\(urlEncode(bdstoken))&newVerify=1&clienttype=0&app_id=\(BaiduConstants.appId)&web=1"
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": "https://yun.baidu.com/disk/main"
            ],
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "百度网盘删除失败")
    }

    public func createCloudShare(
        files: [ShareFile],
        title: String,
        expire: CloudShareExpire,
        passcode: String?,
        credential: String
    ) async throws -> CloudShareResult {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        guard let bdstoken = await getBdstoken(cookie: credential) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败")
        }
        let fsIds = files.map(Self.baiduFsId(of:)).filter { !$0.isEmpty && Int64($0) != nil }
        guard !fsIds.isEmpty else {
            throw ProviderError.missingData("缺少百度文件 fs_id，请刷新目录后重试")
        }
        let rawPwd = (passcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pwd = rawPwd.count == 4 ? rawPwd : SharePlatform.randomSharePasscode(length: 4)
        let fidList = "[\(fsIds.joined(separator: ","))]"
        let body = "fid_list=\(urlEncode(fidList))&schannel=4&channel_list=%5B%5D&period=\(expire.baiduPeriod)&pwd=\(urlEncode(pwd))"
        let url = "https://pan.baidu.com/share/set?channel=chunlei&web=1&app_id=\(BaiduConstants.appId)&bdstoken=\(urlEncode(bdstoken))&clienttype=0"
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "Referer": "https://yun.baidu.com/disk/main"
            ],
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "百度网盘创建分享失败")
        let shortUrl = stringValue(json["shorturl"])
        let link = shortUrl.isEmpty ? stringValue(json["link"]) : shortUrl
        guard !link.isEmpty else { throw ProviderError.missingData("百度未返回分享链接") }
        let returnedExpire = CloudShareExpire.fromBaiduPeriod((json["expiredType"] as? NSNumber)?.intValue) ?? expire
        return CloudShareResult(
            platform: .baidu,
            shareUrl: link,
            passcode: pwd,
            pwdId: stringValue(json["shareid"]),
            title: title.isEmpty ? (files.first?.fname ?? "分享文件") : title,
            expire: returnedExpire
        )
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        let path = Self.baiduPath(of: file)
        let directUrl = try await locateDownload(path: path, cookie: credential)
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: directUrl, size: file.fsize)
    }

    public func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String? {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        guard source.fileSize > 0 else {
            throw ProviderError.apiMessage("百度网盘不支持上传 0 字节空文件")
        }
        guard let bdstoken = await getBdstoken(cookie: credential) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败")
        }
        let io = UploadIO(source: source, onProgress: onProgress)
        io.report(.preparing)

        let base = parentFid.isEmpty || parentFid == "/" ? "" : parentFid.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let remotePath = base.isEmpty ? "/\(source.fileName)" : "/\(base)/\(source.fileName)"
        let chunkSize: Int64 = 4 * 1024 * 1024
        let count = max(1, (source.fileSize + chunkSize - 1) / chunkSize)
        var blocks: [String] = []
        blocks.reserveCapacity(Int(count))
        for idx in 0..<count {
            let start = idx * chunkSize
            blocks.append(try io.digestHex(.md5, start: start, end: min(source.fileSize, start + chunkSize)))
        }
        let blockJsonData = try JSONSerialization.data(withJSONObject: blocks)
        let blockJson = String(data: blockJsonData, encoding: .utf8) ?? "[]"
        let contentMd5 = try io.digestHex(.md5)
        let sliceMd5 = try io.digestHex(.md5, start: 0, end: min(source.fileSize, 256 * 1024))

        let params = "channel=chunlei&web=1&app_id=\(BaiduConstants.appId)&clienttype=0&bdstoken=\(urlEncode(bdstoken))"
        let preBody = "path=\(urlEncode(remotePath))&isdir=0&size=\(source.fileSize)&autoinit=1&rtype=0" +
            "&block_list=\(urlEncode(blockJson))&content-md5=\(contentMd5)&slice-md5=\(sliceMd5)"
        let preResp = try await http.send(
            url: "https://pan.baidu.com/api/precreate?\(params)",
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Referer": "https://pan.baidu.com/disk/main",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
            ],
            body: preBody.data(using: .utf8)
        )
        let preJson = try parseJSON(preResp)
        try checkErrno(preJson, fallback: "百度上传预创建失败")
        if intValue(preJson["return_type"], default: 0) == 2 {
            io.report(.finishing, sent: source.fileSize)
            let fsId = stringValue((preJson["info"] as? [String: Any])?["fs_id"])
            return fsId.isEmpty ? nil : fsId
        }
        let uploadId = stringValue(preJson["uploadid"])
        guard !uploadId.isEmpty else { throw ProviderError.missingData("百度未返回 uploadid") }
        let needed = (preJson["block_list"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue ?? Int(stringValue($0)) }
        let servers = needed.isEmpty ? [] : await fetchBaiduUploadServers(cookie: credential, bdstoken: bdstoken, sign: stringValue(preJson["uploadsign"]))
        guard needed.isEmpty || !servers.isEmpty else {
            throw ProviderError.missingData("未获取到可用的百度上传节点")
        }

        var uploadedIndices = Set<Int>()
        for index in needed {
            guard index >= 0 && Int64(index) < count && uploadedIndices.insert(index).inserted else {
                throw ProviderError.apiMessage("百度分片索引异常（\(index)）")
            }
            let start = Int64(index) * chunkSize
            let end = min(source.fileSize, start + chunkSize)
            let uploadURL = "\(servers[0])/rest/2.0/pcs/superfile2?\(params)&method=upload&type=tmpfile&path=\(urlEncode(remotePath))&uploadid=\(urlEncode(uploadId))&partseq=\(index)"
            let partResp = try await io.send(
                url: uploadURL,
                method: "POST",
                headers: [
                    "Cookie": credential,
                    "User-Agent": BaiduConstants.uaNetdisk
                ],
                start: start,
                end: end,
                retries: 1
            )
            guard partResp.isSuccessful else {
                throw ProviderError.apiMessage("百度分片上传失败（HTTP \(partResp.statusCode)）")
            }
            let remoteMd5 = (partResp.jsonObject()?["md5"] as? String ?? "").lowercased()
            guard remoteMd5 == blocks[index].lowercased() else {
                throw ProviderError.apiMessage("百度分片 MD5 校验不一致")
            }
        }

        io.report(.finishing, sent: source.fileSize)
        let commitBody = "path=\(urlEncode(remotePath))&isdir=0&size=\(source.fileSize)&uploadid=\(urlEncode(uploadId))" +
            "&block_list=\(urlEncode(blockJson))&rtype=0&local_mtime=\(Int64(Date().timeIntervalSince1970))"
        let commitResp = try await http.send(
            url: "https://pan.baidu.com/api/create?a=commit&\(params)",
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Referer": "https://yun.baidu.com/disk/main",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
            ],
            body: commitBody.data(using: .utf8)
        )
        let commitJson = try parseJSON(commitResp)
        try checkErrno(commitJson, fallback: "百度上传合并失败")
        let fsId = stringValue(commitJson["fs_id"])
        return fsId.isEmpty ? nil : fsId
    }

    private func fetchBaiduUploadServers(cookie: String, bdstoken: String, sign: String) async -> [String] {
        var url = "https://d.pcs.baidu.com/rest/2.0/pcs/file?channel=chunlei&web=1&app_id=\(BaiduConstants.appId)&clienttype=0&bdstoken=\(urlEncode(bdstoken))&method=locateupload&upload_version=2.0"
        if !sign.isEmpty {
            url += "&uploadsign=\(urlEncode(sign))"
        }
        guard let resp = try? await http.send(
            url: url,
            headers: ["Cookie": cookie, "User-Agent": BaiduConstants.uaNetdisk]
        ), let json = try? parseJSON(resp) else {
            return []
        }
        var servers: [String] = []
        var seen = Set<String>()
        for key in ["servers", "bak_servers"] {
            for item in (json[key] as? [[String: Any]] ?? []) {
                guard let raw = item["server"] as? String,
                      let parsed = URL(string: raw),
                      parsed.scheme == "https",
                      let host = parsed.host,
                      host.hasSuffix(".pcs.baidu.com") else { continue }
                let normalized = "https://\(host)"
                if seen.insert(normalized).inserted {
                    servers.append(normalized)
                    if servers.count >= 3 { return servers }
                }
            }
        }
        let fallbackHost = stringValue(json["host"])
        if servers.isEmpty && fallbackHost.hasSuffix(".pcs.baidu.com") {
            servers.append("https://\(fallbackHost)")
        }
        return servers
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        let (sekey, shareId, uk) = decodeStoken(session.stoken)
        guard !shareId.isEmpty && !uk.isEmpty else {
            throw ProviderError.missingData("百度分享信息不完整，请重新解析链接")
        }
        let targetDir = toDirFid.isEmpty ? "/" : toDirFid
        _ = try await transfer(
            shareId: shareId,
            uk: uk,
            sekey: sekey,
            fsId: file.fid,
            toDir: targetDir,
            cookie: credential
        )
    }

    // MARK: - 百度个人盘双通道列目录辅助

    private func fetchPersonalList(dir: String, cookie: String, useAppChannel: Bool) async throws -> [ShareFile] {
        let thumbHeaders = [
            "User-Agent": BaiduConstants.uaNetdisk,
            "Referer": "https://yun.baidu.com/"
        ]
        var all: [ShareFile] = []
        var seen = Set<String>()
        let pageSize = 100

        for page in 0..<50 {
            let encodedDir = urlEncode(dir)
            let url: String
            var headers: [String: String] = ["Cookie": cookie]
            if useAppChannel {
                let uid = Self.appDeviceId(cookie: cookie)
                let bdstoken = Self.appBdstoken(cookie: cookie)
                url = "https://pan.baidu.com/api/list?clienttype=1&app_id=\(BaiduConstants.appId)&version=\(BaiduConstants.appVersion)&channel=&bdstoken=\(bdstoken)&devuid=\(uid)&cuid=\(uid)&apn_id=0_0&freeisp=0&queryfree=2&start=\(page * pageSize)&limit=\(pageSize)&preset=0&order=time&desc=1&dir=\(encodedDir)"
                headers["User-Agent"] = BaiduConstants.uaApp
            } else {
                url = "https://pan.baidu.com/api/list?channel=chunlei&clienttype=0&app_id=\(BaiduConstants.appId)&web=1&page=\(page + 1)&num=\(pageSize)&order=time&desc=1&dir=\(encodedDir)"
                headers["User-Agent"] = BaiduConstants.uaWeb
                headers["Referer"] = "https://pan.baidu.com/disk/main"
            }

            let resp = try await http.send(url: url, headers: headers)
            let json = try parseJSON(resp)
            try checkErrno(json, fallback: "获取百度个人盘目录失败")
            let arr = json["list"] as? [[String: Any]] ?? []
            var fresh = 0
            for item in arr {
                let path = stringValue(item["path"])
                let fsId = stringValue(item["fs_id"])
                let isDir = intValue(item["isdir"], default: 0) == 1
                // 目录用 path 作 fid 便于统一导航，fs_id 存 fidToken 供创建分享使用；
                // 文件用 fs_id 作 fid，path 存 fidToken 供 rename/move/delete/locateDownload 使用。
                let id = isDir ? path : (fsId.isEmpty ? path : fsId)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                fresh += 1
                let thumbs = item["thumbs"] as? [String: Any]
                let thumb = [thumbs?["url3"], thumbs?["url2"], thumbs?["url1"]]
                    .compactMap { $0 as? String }
                    .compactMap { FileThumbnail.secure(url: $0, headers: thumbHeaders) }
                    .first
                all.append(ShareFile(
                    fid: id,
                    fname: stringValue(item["server_filename"]),
                    fsize: isDir ? 0 : int64Value(item["size"]),
                    isdir: isDir,
                    pdirFid: dir,
                    fidToken: isDir ? fsId : path,
                    modifyTime: stringValue(item["server_mtime"]),
                    thumbnail: thumb
                ))
            }
            if arr.count < pageSize || fresh == 0 { break }
        }
        return all
    }

    public static func baiduPath(of file: ShareFile) -> String {
        if file.isdir {
            return file.fid
        }
        return file.fidToken.isEmpty ? file.fid : file.fidToken
    }

    public static func baiduFsId(of file: ShareFile) -> String {
        if file.isdir {
            return file.fidToken
        }
        return file.fid
    }

    public static func appBdstoken(cookie: String) -> String {
        md5Hex(extractCookieValue(cookie, name: "BDUSS"))
    }

    public static func appDeviceId(cookie: String) -> String {
        md5Hex("yunx|\(extractCookieValue(cookie, name: "BDUSS"))").uppercased() + "|0"
    }

    private static func extractCookieValue(_ cookie: String, name: String) -> String {
        for part in cookie.split(separator: ";") {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("\(name)=") {
                return String(t.dropFirst(name.count + 1))
            }
        }
        return ""
    }

    private static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
