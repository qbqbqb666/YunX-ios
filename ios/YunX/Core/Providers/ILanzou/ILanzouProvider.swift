//
//  ILanzouProvider.swift
//  YunX
//
//  蓝奏优享版（ilanzou）解析与账号登录实现：
//  - 分享页匿名列目录（apix.ilanzou.com/unproved/share/list）与 302/JSON 直链解析；
//  - 支持账号密码登录获取 appToken + uuid + userId，下载带用户身份更稳定；
//  - 完整携带 Chrome sec-ch-ua 浏览器头防止 ESA WAF 返回空列表。
//

import Foundation

public struct ILanzouAccountInfo: Sendable, Equatable {
    public let userId: String
    public let account: String
    public let nickname: String
}

public final class ILanzouProvider: ShareResolveProvider, Sendable {
    public let platform: SharePlatform = .ilanzou
    let http: HTTPClient

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - 认证登录

    public func getUuid() async throws -> String {
        let url = buildApiURL(path: ILanzouConstants.getUuidURL, uuid: "", appToken: nil, extra: true, params: [])
        let json = try await execApi(url: url, method: "GET", body: nil)
        let uuid = stringValue(json["uuid"])
        guard uuid.count >= 8 && uuid.count <= 128 else {
            throw ProviderError.missingData("获取蓝奏优享设备标识失败")
        }
        return uuid
    }

    public func login(loginName: String, loginPwd: String) async throws -> (payload: ILanzouCredentialPayload, nickname: String) {
        let name = loginName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && !loginPwd.isEmpty else {
            throw ProviderError.apiMessage("请输入账号与密码")
        }
        let uuid = (try? await getUuid()) ?? ILanzouConstants.newUuid()
        let url = buildApiURL(path: ILanzouConstants.loginURL, uuid: uuid, appToken: nil, extra: true, params: [])
        let bodyData = try JSONSerialization.data(withJSONObject: ["loginName": name, "loginPwd": loginPwd])
        let resp = try await http.send(url: url, method: "POST", headers: commonHeaders(isJSON: true), body: bodyData)
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw ProviderError.apiMessage("蓝奏优享登录响应解析失败（HTTP \(resp.statusCode)）")
        }
        let code = intValue(json["code"], default: -1)
        guard code == 200 else {
            let msg = stringValue(json["msg"])
            throw ProviderError.apiMessage(msg.isEmpty ? "蓝奏优享登录失败（错误码 \(code)）" : msg, code: code)
        }
        let token = stringValue((json["data"] as? [String: Any])?["appToken"])
        guard token.count >= 16 else {
            throw ProviderError.missingData("蓝奏优享未返回有效登录令牌")
        }
        let info = await fetchAccountInfo(appToken: token, uuid: uuid)
        let payload = ILanzouCredentialPayload(
            appToken: token,
            uuid: uuid,
            userId: info?.userId ?? "",
            account: info?.account.isEmpty == false ? info!.account : name
        )
        let nickname = info?.nickname.isEmpty == false ? info!.nickname : name
        return (payload, nickname)
    }

    public func fetchAccountInfo(appToken: String, uuid: String) async -> ILanzouAccountInfo? {
        let url = buildApiURL(path: ILanzouConstants.accountMapURL, uuid: uuid, appToken: appToken, extra: true, params: [])
        guard let json = try? await execApi(url: url, method: "GET", body: nil),
              let map = json["map"] as? [String: Any] else {
            return nil
        }
        let userId = stringValue(map["userId"])
        guard !userId.isEmpty && userId != "0" else { return nil }
        let account = stringValue(map["account"])
        let nick = [stringValue(map["nickName"]), stringValue(map["nickname"]), account]
            .first(where: { !$0.isEmpty }) ?? "蓝奏优享用户"
        return ILanzouAccountInfo(userId: userId, account: account, nickname: nick)
    }

    public func fetchNickname(credential: String) async -> String? {
        guard let payload = ILanzouCredentialPayload.decode(from: credential) else { return nil }
        return await fetchAccountInfo(appToken: payload.appToken, uuid: payload.uuid)?.nickname
    }

    // MARK: - ShareResolveProvider

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let payload = ILanzouCredentialPayload.decode(from: credential)
        let uuid = payload?.uuid ?? ILanzouConstants.newUuid()
        return ShareSession(
            platform: .ilanzou,
            shareId: parsed.shareId,
            stoken: uuid,
            title: "蓝奏优享 · \(parsed.shareId)",
            originalLink: parsed.rawUrl,
            passcode: pwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let payload = ILanzouCredentialPayload.decode(from: credential)
        let uuid = payload?.uuid ?? (session.stoken.isEmpty ? ILanzouConstants.newUuid() : session.stoken)
        let rawFolder = ILanzouConstants.stripPrefix(dirFid)
        let folderParam = (rawFolder.isEmpty || rawFolder == ILanzouConstants.rootFolderId) ? nil : rawFolder

        var all: [ShareFile] = []
        var seen = Set<String>()

        for page in 1...1000 {
            var params: [(String, String)] = []
            if let folderParam {
                params.append(("folderId", folderParam))
            }
            params.append(("offset", "\(page)"))
            params.append(("limit", "\(ILanzouConstants.pageSize)"))

            let url = buildShareURL(path: ILanzouConstants.shareListURL, uuid: uuid, shareId: session.shareId, params: params)
            let resp = try await http.send(url: url, headers: commonHeaders(isJSON: false))
            guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
                throw ProviderError.apiMessage("蓝奏优享分享列表请求失败（HTTP \(resp.statusCode)）")
            }
            let code = intValue(json["code"], default: -1)
            guard code == 200 else {
                let msg = stringValue(json["msg"])
                throw ProviderError.apiMessage(msg.isEmpty ? "蓝奏优享分享解析失败（错误码 \(code)）" : msg, code: code)
            }
            guard let list = json["list"] as? [[String: Any]], !list.isEmpty else { break }

            var added = 0
            for item in list {
                if let file = parseItem(item), seen.insert(file.fid).inserted {
                    all.append(file)
                    added += 1
                }
            }
            if added == 0 { break }
            let totalPage = intValue(json["totalPage"], default: 0)
            if totalPage > 0 && page >= totalPage { break }
            if totalPage <= 0 && list.count < ILanzouConstants.pageSize { break }
        }
        return all
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        let payload = ILanzouCredentialPayload.decode(from: credential)
        let uuid = payload?.uuid ?? (session.stoken.isEmpty ? ILanzouConstants.newUuid() : session.stoken)
        let userId = payload?.userId ?? ""
        return try await fetchShareDownload(session: session, file: file, userId: userId, uuid: uuid)
    }

    public func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let uuid = session.stoken.isEmpty ? ILanzouConstants.newUuid() : session.stoken
        return try await fetchShareDownload(session: session, file: file, userId: "", uuid: uuid)
    }

    // MARK: - 内部实现

    private func fetchShareDownload(
        session: ShareSession,
        file: ShareFile,
        userId: String,
        uuid: String
    ) async throws -> DownloadLink {
        let rawFileId = ILanzouConstants.stripPrefix(file.fid)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let params: [(String, String)] = [
            ("downloadId", ILanzouConstants.aesHex("\(rawFileId)|\(userId)")),
            ("enable", "1"),
            ("devType", ILanzouConstants.devType),
            ("uuid", uuid),
            ("timestamp", ILanzouConstants.aesHex("\(ts)")),
            ("auth", ILanzouConstants.aesHex("\(rawFileId)|\(ts)")),
            ("shareId", session.shareId)
        ]
        let query = params.map { "\($0.0)=\(ILanzouConstants.encodeToken($0.1))" }.joined(separator: "&")
        let url = "\(ILanzouConstants.shareRedirectURL)?\(query)"
        let resp = try await http.send(url: url, headers: commonHeaders(isJSON: false), followRedirects: false)

        if (300..<400).contains(resp.statusCode), let location = resp.header("Location"), !location.isEmpty {
            let resolved: String
            if let base = URL(string: ILanzouConstants.shareApiBase),
               let abs = URL(string: location, relativeTo: base)?.absoluteString {
                resolved = abs
            } else {
                resolved = location
            }
            return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: resolved, size: file.fsize)
        }

        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw ProviderError.missingData("蓝奏优享未返回有效下载直链")
        }
        let directUrl = [
            stringValue(json["url"]),
            stringValue((json["data"] as? [String: Any])?["url"])
        ].first(where: { !$0.isEmpty }) ?? ""
        guard !directUrl.isEmpty else {
            let msg = stringValue(json["msg"])
            throw ProviderError.apiMessage(msg.isEmpty ? "无法获取蓝奏优享下载直链" : msg)
        }
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: directUrl, size: file.fsize)
    }

    private func parseItem(_ item: [String: Any]) -> ShareFile? {
        let fileType = intValue(item["fileType"], default: 0)
        let modTime = stringValue(item["updTime"]).isEmpty ? stringValue(item["addTime"]) : stringValue(item["updTime"])
        if fileType == 2 {
            let rawId = stringValue(item["folderId"])
            guard !rawId.isEmpty && rawId != "0" else { return nil }
            return ShareFile(
                fid: ILanzouConstants.folderPrefix + rawId,
                fname: stringValue(item["folderName"]),
                fsize: 0,
                isdir: true,
                pdirFid: "",
                fidToken: "",
                modifyTime: modTime
            )
        } else {
            let rawId = stringValue(item["fileId"])
            guard !rawId.isEmpty && rawId != "0" else { return nil }
            let sizeBytes = int64Value(item["fileSize"]) * 1024
            return ShareFile(
                fid: ILanzouConstants.filePrefix + rawId,
                fname: stringValue(item["fileName"]),
                fsize: sizeBytes,
                isdir: false,
                pdirFid: "",
                fidToken: "",
                modifyTime: modTime
            )
        }
    }

    private func buildApiURL(
        path: String,
        uuid: String,
        appToken: String?,
        extra: Bool,
        params: [(String, String)]
    ) -> String {
        let ts = ILanzouConstants.aesHex("\(Int64(Date().timeIntervalSince1970 * 1000))")
        var all: [(String, String)] = [
            ("uuid", uuid),
            ("devType", ILanzouConstants.devType),
            ("devCode", uuid),
            ("devModel", ILanzouConstants.devModel),
            ("devVersion", ILanzouConstants.devVersion),
            ("appVersion", ""),
            ("timestamp", ts)
        ]
        if let appToken, !appToken.isEmpty {
            all.append(("appToken", appToken))
        }
        if extra {
            all.append(("extra", "2"))
        }
        all.append(contentsOf: params)
        let query = all.map { "\($0.0)=\(ILanzouConstants.encodeToken($0.1))" }.joined(separator: "&")
        return "\(path)?\(query)"
    }

    private func buildShareURL(
        path: String,
        uuid: String,
        shareId: String,
        params: [(String, String)]
    ) -> String {
        let ts = ILanzouConstants.aesHex("\(Int64(Date().timeIntervalSince1970 * 1000))")
        var all: [(String, String)] = [
            ("uuid", uuid),
            ("devType", ILanzouConstants.devType),
            ("devCode", uuid),
            ("devModel", ILanzouConstants.shareDevModel),
            ("devVersion", ILanzouConstants.devVersion),
            ("appVersion", ""),
            ("timestamp", ts),
            ("extra", "2"),
            ("shareId", shareId)
        ]
        all.append(contentsOf: params)
        let query = all.map { "\($0.0)=\(ILanzouConstants.encodeToken($0.1))" }.joined(separator: "&")
        return "\(path)?\(query)"
    }

    private func execApi(url: String, method: String, body: Data?) async throws -> [String: Any] {
        let resp = try await http.send(url: url, method: method, headers: commonHeaders(isJSON: body != nil), body: body)
        guard resp.isSuccessful,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw ProviderError.apiMessage("蓝奏优享请求失败（HTTP \(resp.statusCode)）")
        }
        let code = intValue(json["code"], default: -1)
        guard code == 200 else {
            if code == -1 || code == -2 {
                throw ProviderError.apiMessage("蓝奏优享登录已过期，请重新登录", code: code)
            }
            let msg = stringValue(json["msg"])
            throw ProviderError.apiMessage(msg.isEmpty ? "蓝奏优享接口错误（\(code)）" : msg, code: code)
        }
        return json
    }

    private func commonHeaders(isJSON: Bool) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": ILanzouConstants.webUA,
            "Origin": ILanzouConstants.webSite,
            "Referer": ILanzouConstants.downloadReferer,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "sec-ch-ua": "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"",
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": "\"Windows\"",
            "sec-fetch-dest": "empty",
            "sec-fetch-mode": "cors",
            "sec-fetch-site": "same-site"
        ]
        if isJSON {
            h["Content-Type"] = "application/json; charset=utf-8"
        }
        return h
    }

    private func stringValue(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private func intValue(_ any: Any?, default def: Int) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let v = Int(s) { return v }
        return def
    }

    private func int64Value(_ any: Any?) -> Int64 {
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let v = Int64(s) { return v }
        return 0
    }
}
