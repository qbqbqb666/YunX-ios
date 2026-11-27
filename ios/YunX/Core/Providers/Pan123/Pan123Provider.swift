//
//  Pan123Provider.swift
//  YunX
//
//  123 云盘完整协议实现：
//  - 匿名分享列目录（/b/api/share/get，无提取码时不传 SharePwd）；
//  - 原生账号密码直登（user.123pan.cn/api/user/sign_in → Bearer JWT）；
//  - 签名鉴权获取分享直链 + Base64 解包 + auto_redirect JSON 跟随。
//

import Foundation

public final class Pan123Provider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .pan123

    internal let http: HTTPClient
    internal let loginUUID: String

    public init(http: HTTPClient = .shared, loginUUID: String = Pan123Constants.persistentLoginUUID()) {
        self.http = http
        self.loginUUID = loginUUID
    }

    // MARK: - 原生账号密码登录

    public func passwordLogin(account: String, password: String) async throws -> String {
        let passport = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !passport.isEmpty, !password.isEmpty else {
            throw ProviderError.apiMessage("请输入 123 云盘手机号/邮箱和密码")
        }
        let bodyDict: [String: Any] = [
            "passport": passport,
            "password": password,
            "remember": false
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        let headers = [
            "platform": Pan123Constants.platformWeb,
            "app-version": Pan123Constants.appVersionSignIn,
            "loginuuid": loginUUID,
            "Origin": Pan123Constants.signInOrigin,
            "Referer": Pan123Constants.signInReferer,
            "User-Agent": Pan123Constants.webUA,
            "Content-Type": "application/json; charset=utf-8"
        ]
        let resp = try await http.send(url: Pan123Constants.signInURL, method: "POST", headers: headers, body: bodyData)
        let json = (try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
        let code = (json["code"] as? NSNumber)?.intValue ?? -1
        let data = json["data"] as? [String: Any]
        let token = data?["token"] as? String ?? ""

        if resp.isSuccessful && code == 200 && Pan123Signer.isValidToken(token) {
            return token
        }

        let serverMsg = (json["message"] as? String ?? "").lowercased()
        if resp.statusCode == 429 || code == 429 || serverMsg.contains("频繁") || serverMsg.contains("频率") {
            throw ProviderError.apiMessage("登录请求过于频繁，请稍后再试")
        }
        if serverMsg.contains("验证码") || serverMsg.contains("滑块") || serverMsg.contains("verify") || serverMsg.contains("captcha") {
            throw ProviderError.apiMessage("触发安全验证，请改用「网页登录」或手动粘贴 authorToken")
        }
        if serverMsg.contains("冻结") || serverMsg.contains("封") {
            throw ProviderError.apiMessage("账号状态异常或已被限制，请先在官网检查")
        }
        throw ProviderError.apiMessage("登录失败，请检查账号和密码是否正确")
    }

    public func fetchNickname(credential: String) async -> String? {
        guard !credential.isEmpty else { return nil }
        guard let json = try? await authGet(url: Pan123Constants.userInfoURL, path: "/b/api/user/info", token: credential),
              (json["code"] as? NSNumber)?.intValue == 0,
              let data = json["data"] as? [String: Any],
              let nick = data["Nickname"] as? String, !nick.isEmpty else {
            return nil
        }
        return nick
    }

    // MARK: - 分享解析与列目录（匿名）

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let sharePwd = (pwd?.isEmpty == false ? pwd : parsed.pwd) ?? ""
        let (files, _) = try await getShareFilesPage(shareKey: parsed.shareId, sharePwd: sharePwd, parentFileId: "0", page: 1)
        let title = files.first?.fname.isEmpty == false ? files.first!.fname : parsed.shareId
        return ShareSession(
            platform: .pan123,
            shareId: parsed.shareId,
            stoken: sharePwd,
            title: title,
            originalLink: parsed.rawUrl,
            passcode: sharePwd.isEmpty ? nil : sharePwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let parent = dirFid.isEmpty ? "0" : dirFid
        var all: [ShareFile] = []
        for page in 1...50 {
            let (batch, nextCursor) = try await getShareFilesPage(
                shareKey: session.shareId,
                sharePwd: session.stoken,
                parentFileId: parent,
                page: page
            )
            all.append(contentsOf: batch)
            if batch.isEmpty || nextCursor == nil { break }
        }
        return all
    }

    private func getShareFilesPage(
        shareKey: String,
        sharePwd: String,
        parentFileId: String,
        page: Int
    ) async throws -> ([ShareFile], String?) {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        var url = "\(Pan123Constants.shareGetURL)?limit=100&next=0&orderBy=file_name&orderDirection=asc&shareKey=\(enc(shareKey))&ParentFileId=\(parentFileId)&Page=\(page)"
        // 无提取码时不传 SharePwd（传空串服务端会报 400）
        if !sharePwd.isEmpty {
            url += "&SharePwd=\(enc(sharePwd))"
        }
        let resp = try await http.send(url: url, headers: ["User-Agent": Pan123Constants.dartUA])
        let json = try parseJSON(resp: resp)
        try checkCodeZero(json, fallback: "获取 123 分享列表失败")
        guard let data = json["data"] as? [String: Any] else {
            return ([], nil)
        }
        if (data["Expired"] as? Bool) == true {
            throw ProviderError.apiMessage("该 123 云盘分享链接已失效")
        }
        let files = parseInfoList(data)
        let nextStr = data["Next"] as? String ?? "-1"
        let nextCursor: String? = (nextStr == "-1") ? nil : nextStr
        return (files, nextCursor)
    }

    // MARK: - 分享直链（需登录 JWT + 签名）

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard !credential.isEmpty else {
            throw ProviderError.loginRequired(.pan123)
        }
        let parts = file.fidToken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let s3KeyFlag = parts.indices.contains(0) ? parts[0] : ""
        let etag = parts.indices.contains(1) ? parts[1] : ""

        let bodyDict: [String: Any] = [
            "ShareKey": session.shareId,
            "FileID": Int64(file.fid) ?? 0,
            "S3KeyFlag": s3KeyFlag,
            "Size": file.fsize,
            "Etag": etag
        ]
        let json = try await authPost(
            url: Pan123Constants.shareDownloadInfoURL,
            path: "/b/api/share/download/info",
            body: bodyDict,
            token: credential,
            platformHeader: Pan123Constants.platformAndroid,
            appVersionHeader: Pan123Constants.appVersionAndroid
        )
        try checkCodeZero(json, fallback: "获取 123 下载直链失败")
        guard let data = json["data"] as? [String: Any],
              let rawDownload = data["DownloadURL"] as? String, !rawDownload.isEmpty else {
            throw ProviderError.missingData("123 响应缺少 DownloadURL")
        }
        let decoded = Pan123Signer.decodeDownloadURL(rawDownload) ?? rawDownload
        let realUrl = await followRedirectURL(decoded)
        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: realUrl,
            size: file.fsize
        )
    }

    // MARK: - 内部请求与重定向探测

    internal func followRedirectURL(_ initial: String) async -> String {
        var current = initial
        for _ in 0..<5 {
            guard let next = await probeJSONRedirect(current) else { return current }
            current = next
        }
        return current
    }

    private func probeJSONRedirect(_ url: String) async -> String? {
        let headers = [
            "Referer": Pan123Constants.downloadReferer,
            "User-Agent": Pan123Constants.dartUA
        ]
        guard let urlObj = URL(string: url) else { return nil }
        var req = URLRequest(url: urlObj)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        do {
            let (bytes, response) = try await http.apiSession.bytes(for: req)
            defer { bytes.task.cancel() }
            guard let httpResp = response as? HTTPURLResponse else { return nil }
            let len = httpResp.expectedContentLength
            // 只在响应体很小（≤8KB）时读取判断是否是 auto_redirect JSON 跳转页
            guard len >= 0 && len <= 8192 else { return nil }
            var buf = Data()
            for try await b in bytes {
                buf.append(b)
                if buf.count > 8192 { return nil }
            }
            guard let json = try? JSONSerialization.jsonObject(with: buf) as? [String: Any],
                  let data = json["data"] as? [String: Any],
                  let redirect = data["redirect_url"] as? String,
                  !redirect.isEmpty else {
                return nil
            }
            return redirect
        } catch {
            return nil
        }
    }

    internal func authGet(url: String, path: String, token: String) async throws -> [String: Any] {
        let sign = Pan123Signer.makeSign(path: path)
        let headers = [
            "platform": Pan123Constants.platformWeb,
            "app-version": Pan123Constants.appVersionWeb,
            "authorization": "Bearer \(token)",
            "loginuuid": loginUUID,
            "auth-key": sign.authKey,
            "auth-value": sign.authValue,
            "User-Agent": Pan123Constants.webUA,
            "Accept": "application/json, text/plain, */*"
        ]
        let resp = try await http.send(url: url, method: "GET", headers: headers)
        return try parseJSON(resp: resp)
    }

    internal func authPost(
        url: String,
        path: String,
        body: [String: Any],
        token: String,
        platformHeader: String = Pan123Constants.platformWeb,
        appVersionHeader: String = Pan123Constants.appVersionWeb
    ) async throws -> [String: Any] {
        let sign = Pan123Signer.makeSign(path: path)
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let headers = [
            "platform": platformHeader,
            "app-version": appVersionHeader,
            "authorization": "Bearer \(token)",
            "loginuuid": loginUUID,
            "auth-key": sign.authKey,
            "auth-value": sign.authValue,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": Pan123Constants.webUA
        ]
        let resp = try await http.send(url: url, method: "POST", headers: headers, body: bodyData)
        return try parseJSON(resp: resp)
    }

    internal func parseJSON(resp: HTTPResponseData) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        return json
    }

    internal func checkCodeZero(_ json: [String: Any], fallback: String) throws {
        let code = (json["code"] as? NSNumber)?.intValue ?? -1
        guard code != 0 else { return }
        let msg = (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        throw ProviderError.apiMessage(msg, code: code)
    }

    internal func parseInfoList(_ data: [String: Any]) -> [ShareFile] {
        guard let arr = data["InfoList"] as? [[String: Any]] else { return [] }
        return arr.map { item in
            let typeVal = (item["Type"] as? NSNumber)?.intValue ?? 0
            let fid = Self.stringValue(item["FileId"])
            let pdir = Self.stringValue(item["ParentFileId"])
            let s3 = item["S3KeyFlag"] as? String ?? ""
            let etag = item["Etag"] as? String ?? ""
            let node = item["StorageNode"] as? String ?? ""
            return ShareFile(
                fid: fid,
                fname: item["FileName"] as? String ?? "",
                fsize: (item["Size"] as? NSNumber)?.int64Value ?? 0,
                isdir: typeVal == 1,
                pdirFid: pdir,
                fidToken: "\(s3)|\(etag)|\(node)",
                modifyTime: item["UpdateAt"] as? String ?? ""
            )
        }
    }

    private static func stringValue(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
