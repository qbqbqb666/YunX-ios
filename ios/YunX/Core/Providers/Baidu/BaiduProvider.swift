//
//  BaiduProvider.swift
//  YunX
//
//  百度网盘分享解析器：
//  - share/verify 提取 randsk（sekey）；
//  - xpan/share?method=list 浏览目录（顶层 root=1，子目录 root=0 且携带 BDCLND Cookie）；
//  - 登录态下载走「临时目录转存 -> locatedownload（优先 appall encrypt=0 明文 HTTPS）-> 立即清理临时文件」。
//

import Foundation

public final class BaiduProvider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .baidu
    private let http: HTTPClient
    private let tokenLock = NSLock()
    private var cachedBdstoken: String?

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func fetchNickname(credential: String) async -> String? {
        guard BaiduConstants.isValidCookie(credential) else { return nil }
        guard let result = await fetchTemplateVariable(cookie: credential, fields: "[\"username\"]") else {
            return nil
        }
        let name = stringValue(result["username"])
        return name.isEmpty ? nil : name
    }

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let surl = parsed.shareId
        let effectivePwd = (pwd ?? parsed.pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var sekey = ""
        if !effectivePwd.isEmpty {
            sekey = try await verifyShare(surl: surl, pwd: effectivePwd, cookie: credential)
        }
        let rootList = try await listShareRaw(surl: surl, sekey: sekey, dir: "/", cookie: credential)
        // stoken 编码：sekey|shareId|uk（供 transfer 使用）
        let stoken = "\(sekey)|\(rootList.shareId)|\(rootList.uk)"
        return ShareSession(
            platform: .baidu,
            shareId: surl,
            stoken: stoken,
            title: rootList.title.isEmpty ? "百度网盘分享" : rootList.title,
            originalLink: parsed.rawUrl,
            passcode: effectivePwd.isEmpty ? nil : effectivePwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let (sekey, _, _) = decodeStoken(session.stoken)
        let dir = dirFid.isEmpty ? "/" : dirFid
        let res = try await listShareRaw(surl: session.shareId, sekey: sekey, dir: dir, cookie: credential)
        return res.files
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        let (sekey, shareId, uk) = decodeStoken(session.stoken)
        guard !shareId.isEmpty && !uk.isEmpty else {
            throw ProviderError.missingData("百度分享元数据缺失，请重新解析链接")
        }

        let tempDir = "/\(BaiduConstants.tempDirName)"
        _ = await createDir(path: tempDir, cookie: credential)

        let transferRes = try await transfer(
            shareId: shareId,
            uk: uk,
            sekey: sekey,
            fsId: file.fid,
            toDir: tempDir,
            cookie: credential
        )
        defer {
            Task.detached { [self, path = transferRes.path, credential] in
                await self.deleteFile(path: path, cookie: credential)
            }
        }
        let directUrl = try await locateDownload(path: transferRes.path, cookie: credential)
        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: directUrl,
            size: file.fsize
        )
    }

    // MARK: - 内部百度 API

    private struct ShareListResult {
        let title: String
        let shareId: String
        let uk: String
        let files: [ShareFile]
    }

    private func fetchTemplateVariable(cookie: String, fields: String) async -> [String: Any]? {
        let url = "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=\(BaiduConstants.appId)&web=1&fields=\(urlEncode(fields))"
        guard let resp = try? await http.send(
            url: url,
            headers: [
                "Cookie": cookie,
                "User-Agent": BaiduConstants.uaWeb
            ]
        ), resp.isSuccessful,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              intValue(json["errno"], default: -1) == 0 else {
            return nil
        }
        return json["result"] as? [String: Any]
    }

    private func getBdstoken(cookie: String) async -> String? {
        let existing: String? = tokenLock.withLock { cachedBdstoken }
        if let existing, !existing.isEmpty { return existing }
        guard let res = await fetchTemplateVariable(cookie: cookie, fields: "[\"bdstoken\"]") else { return nil }
        let token = stringValue(res["bdstoken"])
        guard !token.isEmpty else { return nil }
        tokenLock.withLock { cachedBdstoken = token }
        return token
    }

    private func verifyShare(surl: String, pwd: String, cookie: String) async throws -> String {
        let body = "pwd=\(urlEncode(pwd))&vcode_str=&vcode="
        var headers: [String: String] = [
            "User-Agent": BaiduConstants.uaWeb,
            "Referer": "https://pan.baidu.com/s/\(surl)",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let resp = try await http.send(
            url: "https://pan.baidu.com/share/verify?surl=\(urlEncode(surl))",
            method: "POST",
            headers: headers,
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "百度网盘提取码校验失败")
        let randsk = stringValue(json["randsk"])
        guard !randsk.isEmpty else {
            throw ProviderError.missingData("百度网盘未返回分享密钥（randsk）")
        }
        return randsk
    }

    private func listShareRaw(surl: String, sekey: String, dir: String, cookie: String) async throws -> ShareListResult {
        let isRoot = dir.isEmpty || dir == "/"
        let rootFlag = isRoot ? "1" : "0"
        var url = "https://pan.baidu.com/rest/2.0/xpan/share?method=list" +
            "&shorturl=\(urlEncode(surl))&page=1&num=100&root=\(rootFlag)&dir=\(urlEncode(isRoot ? "/" : dir))"
        if !sekey.isEmpty { url += "&sekey=\(sekey)" }

        let authCookie: String
        if !sekey.isEmpty && !cookie.contains("BDCLND=") {
            authCookie = cookie.isEmpty ? "BDCLND=\(sekey)" : "\(cookie); BDCLND=\(sekey)"
        } else {
            authCookie = cookie
        }

        var headers: [String: String] = [
            "User-Agent": BaiduConstants.uaWeb,
            "Referer": "https://pan.baidu.com/s/\(surl)"
        ]
        if !authCookie.isEmpty { headers["Cookie"] = authCookie }

        let resp = try await http.send(url: url, headers: headers)
        let json = try parseJSON(resp)
        let errno = intValue(json["errno"], default: 0)
        if errno != 0 {
            if sekey.isEmpty {
                if errno == -6 {
                    throw ProviderError.apiMessage("该百度分享需要提取码或登录后查看（errno=\(errno)）")
                }
                throw ProviderError.apiMessage("该百度分享需要提取码，请输入提取码后重试（errno=\(errno)）")
            }
            try checkErrno(json, fallback: "获取百度分享文件列表失败")
        }

        let arr = json["list"] as? [[String: Any]] ?? []
        let files: [ShareFile] = arr.compactMap { item in
            let isDir = stringValue(item["isdir"]) == "1"
            let path = stringValue(item["path"])
            let fsId = stringValue(item["fs_id"])
            let id = isDir ? path : fsId
            guard !id.isEmpty else { return nil }
            return ShareFile(
                fid: id,
                fname: stringValue(item["server_filename"]),
                fsize: isDir ? 0 : int64Value(item["size"]),
                isdir: isDir,
                pdirFid: path,
                fidToken: "",
                modifyTime: stringValue(item["server_mtime"])
            )
        }
        return ShareListResult(
            title: stringValue(json["title"]),
            shareId: stringValue(json["share_id"]),
            uk: stringValue(json["uk"]),
            files: files
        )
    }

    private func createDir(path: String, cookie: String) async -> Bool {
        guard let bdstoken = await getBdstoken(cookie: cookie) else { return false }
        let body = "path=\(urlEncode(path))&isdir=1&size&block_list=%5B%5D&method=post&dataType=json"
        let url = "https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id=\(BaiduConstants.appId)&clienttype=0&bdstoken=\(urlEncode(bdstoken))"
        guard let resp = try? await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": cookie,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Referer": "https://yun.baidu.com/disk/main",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
            ],
            body: body.data(using: .utf8)
        ),
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return false
        }
        return intValue(json["errno"], default: -1) == 0
    }

    private func transfer(
        shareId: String,
        uk: String,
        sekey: String,
        fsId: String,
        toDir: String,
        cookie: String
    ) async throws -> (fsId: String, path: String) {
        guard let bdstoken = await getBdstoken(cookie: cookie) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败，请检查 Cookie 是否有效")
        }
        let url = "https://pan.baidu.com/share/transfer?shareid=\(urlEncode(shareId))&from=\(urlEncode(uk))" +
            "&channel=chunlei&sekey=\(sekey)&ondup=newcopy&web=1&app_id=\(BaiduConstants.appId)&bdstoken=\(urlEncode(bdstoken))&clienttype=0"
        let body = "fsidlist=%5B%22\(urlEncode(fsId))%22%5D&path=\(urlEncode(toDir))"
        let authCookie = cookie.contains("BDCLND=") ? cookie : "\(cookie); BDCLND=\(sekey)"
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": authCookie,
                "User-Agent": BaiduConstants.uaWeb,
                "Origin": "https://pan.baidu.com",
                "Referer": "https://pan.baidu.com/s/",
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
            ],
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "百度网盘临时转存失败")
        let extra = json["extra"] as? [String: Any]
        let list = extra?["list"] as? [[String: Any]]
        let first = list?.first
        let newFsId = stringValue(first?["to_fs_id"])
        let newPath = stringValue(first?["to"])
        guard !newFsId.isEmpty && !newPath.isEmpty else {
            throw ProviderError.missingData("百度转存未返回目标文件路径")
        }
        return (newFsId, newPath)
    }

    private func locateDownload(path: String, cookie: String) async throws -> String {
        let time = Int64(Date().timeIntervalSince1970)
        let url = "https://d.pcs.baidu.com/rest/2.0/pcs/file" +
            "?method=locatedownload&app_id=\(BaiduConstants.appId)&clienttype=17&ver=4.0" +
            "&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1" +
            "&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1" +
            "&err_ver=1.0&network_type=WIFI&channel=0" +
            "&path=\(urlEncode(path))&time=\(time)" +
            "&rand=5ed606e9da222cde0474cdf70eda884b" +
            "&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF" +
            "&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF" +
            "&deviceid=348642637967375013" +
            "&psign=860a071f77c860e8cea06e4e54c518f3" +
            "&version=2.2.111.34&version_app=12.24.6&vip=0"
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": cookie,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded"
            ],
            body: "0".data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkErrno(json, fallback: "获取百度高速直链失败")
        let candidates = (json["urls"] as? [[String: Any]] ?? []).filter { !stringValue($0["url"]).isEmpty }

        // 优先 encrypt=0 明文 HTTPS 通道（appall01/02），避开 encrypt=1 加密通道
        let plainHttps = candidates.first(where: { intValue($0["encrypt"], default: 1) == 0 && stringValue($0["url"]).hasPrefix("https") })
        let plainAny = candidates.first(where: { intValue($0["encrypt"], default: 1) == 0 })
        let anyHttps = candidates.first(where: { stringValue($0["url"]).hasPrefix("https") })
        let picked = plainHttps ?? plainAny ?? anyHttps ?? candidates.first
        guard let direct = picked.map({ stringValue($0["url"]) }), !direct.isEmpty else {
            throw ProviderError.missingData("百度接口未返回可用直链")
        }
        return direct
    }

    private func deleteFile(path: String, cookie: String) async {
        guard let bdstoken = await getBdstoken(cookie: cookie) else { return }
        let body = "filelist=\(urlEncode("[\"\(path)\"]"))"
        let url = "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete" +
            "&bdstoken=\(urlEncode(bdstoken))&newVerify=1&clienttype=0&app_id=\(BaiduConstants.appId)&web=1"
        _ = try? await http.send(
            url: url,
            method: "POST",
            headers: [
                "Cookie": cookie,
                "User-Agent": BaiduConstants.uaNetdisk,
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
            ],
            body: body.data(using: .utf8)
        )
    }

    // MARK: - 辅助工具

    private func decodeStoken(_ stoken: String) -> (sekey: String, shareId: String, uk: String) {
        let parts = stoken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let sekey = parts.indices.contains(0) ? parts[0] : ""
        let shareId = parts.indices.contains(1) ? parts[1] : ""
        let uk = parts.indices.contains(2) ? parts[2] : ""
        return (sekey, shareId, uk)
    }

    private func parseJSON(_ resp: HTTPResponseData) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        return obj
    }

    private func checkErrno(_ json: [String: Any], fallback: String) throws {
        let errno = intValue(json["errno"], default: 0)
        if errno == 0 { return }
        let msg = [json["err_msg"], json["errmsg"], json["show_msg"]]
            .compactMap { $0 as? String }
            .first(where: { !$0.isEmpty && $0 != "null" }) ?? ""
        throw ProviderError.apiMessage(msg.isEmpty ? "\(fallback)（errno=\(errno)）" : "\(msg)（errno=\(errno)）")
    }

    private func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func stringValue(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private func intValue(_ v: Any?, default def: Int = 0) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return def
    }

    private func int64Value(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return 0
    }
}
