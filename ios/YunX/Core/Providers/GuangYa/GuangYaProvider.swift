//
//  GuangYaProvider.swift
//  YunX
//
//  光鸭云盘解析与认证引擎：
//  - 支持账号密码登录、短信验证码登录/注册、Token 自动刷新；
//  - 公开分享完全支持免登录列目录与直链下载；
//  - 分享受限（业务码 207）时，已登录用户自动走「临时子目录转存 -> 个人盘取直链 -> 下载后清理」。
//

import Foundation

public struct GuangYaSmsChallenge: Sendable {
    public let verificationId: String
    public let isUser: Bool
    public let expiresIn: Int
    public let deviceId: String
    public let deviceSign: String
}

public final class GuangYaProvider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .guangya
    private let http: HTTPClient
    private let publicDeviceId: String = GuangYaConstants.newDeviceId()

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - 原生密码 / 短信登录

    public func signIn(username: String, password: String) async throws -> (payload: GuangYaCredentialPayload, nickname: String) {
        let deviceId = GuangYaConstants.newDeviceId()
        let deviceSign = GuangYaConstants.newDeviceSign(deviceId: deviceId)
        let normalized = GuangYaConstants.normalizeAccount(username)
        let meta = metaFor(normalized)

        var captcha = await initCaptcha(deviceId: deviceId, deviceSign: deviceSign, meta: meta, action: "POST:/v1/auth/signin")
        for attempt in 0..<3 {
            let body: [String: Any] = [
                "client_id": GuangYaConstants.clientId,
                "username": normalized,
                "password": password
            ]
            var headers = accountHeaders(deviceId: deviceId, deviceSign: deviceSign, token: nil)
            if let ct = captcha.token, !ct.isEmpty { headers["X-Captcha-Token"] = ct }
            let resp = try await http.send(
                url: GuangYaConstants.signinURL,
                method: "POST",
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: body)
            )
            let json = try parseJSON(resp)
            let code = stringValue(json["code"])
            let err = stringValue(json["error"])
            if (code == "captcha_required" || err == "captcha_required" || code == "captcha_invalid" || err == "captcha_invalid") && attempt < 2 {
                captcha = await initCaptcha(deviceId: deviceId, deviceSign: deviceSign, meta: meta, action: "POST:/v1/auth/signin")
                continue
            }
            guard isSuccess(json) else {
                let msg = firstNonEmpty(stringValue(json["msg"]), stringValue(json["message"]), stringValue(json["error_description"]))
                throw ProviderError.apiMessage(msg.isEmpty ? "光鸭登录失败（\(code.isEmpty ? err : code)）" : msg)
            }
            let payload = try parseTokens(json, deviceId: deviceId, deviceSign: deviceSign, account: normalized)
            let nick = await fetchNickname(credential: payload.encodedString()) ?? normalized
            return (payload, nick)
        }
        throw ProviderError.apiMessage("光鸭人机校验失败，请稍后重试")
    }

    public func sendSmsCode(phoneNumber: String) async throws -> GuangYaSmsChallenge {
        let deviceId = GuangYaConstants.newDeviceId()
        let deviceSign = GuangYaConstants.newDeviceSign(deviceId: deviceId)
        let normalized = GuangYaConstants.normalizeAccount(phoneNumber)
        let meta: [String: Any] = ["phone_number": normalized]

        var captcha = await initCaptcha(deviceId: deviceId, deviceSign: deviceSign, meta: meta, action: "POST:/v1/auth/verification")
        if let url = captcha.url, !url.isEmpty {
            throw ProviderError.apiMessage("当前需人机验证，请改用账号密码登录光鸭云盘")
        }
        for attempt in 0..<3 {
            let body: [String: Any] = [
                "client_id": GuangYaConstants.clientId,
                "phone_number": normalized,
                "target": "ANY"
            ]
            var headers = accountHeaders(deviceId: deviceId, deviceSign: deviceSign, token: nil)
            headers["X-Captcha-Token"] = captcha.token ?? ""
            let resp = try await http.send(
                url: GuangYaConstants.verificationURL,
                method: "POST",
                headers: headers,
                body: try JSONSerialization.data(withJSONObject: body)
            )
            let json = try parseJSON(resp)
            let code = stringValue(json["code"])
            let err = stringValue(json["error"])
            if (code == "captcha_required" || err == "captcha_required" || code == "captcha_invalid" || err == "captcha_invalid") && attempt < 2 {
                captcha = await initCaptcha(deviceId: deviceId, deviceSign: deviceSign, meta: meta, action: "POST:/v1/auth/verification")
                continue
            }
            guard isSuccess(json) else {
                let msg = firstNonEmpty(stringValue(json["msg"]), stringValue(json["message"]), stringValue(json["error_description"]))
                throw ProviderError.apiMessage(msg.isEmpty ? "发送短信验证码失败" : msg)
            }
            let node = (json["data"] as? [String: Any]) ?? json
            let verId = firstNonEmpty(stringValue(node["verification_id"]), stringValue(json["verification_id"]))
            guard !verId.isEmpty else {
                throw ProviderError.apiMessage("验证码发送过于频繁，请稍后再试")
            }
            let isUser = (node["is_user"] as? Bool) ?? (json["is_user"] as? Bool) ?? true
            let expiresIn = intValue(node["expires_in"], default: 600)
            return GuangYaSmsChallenge(
                verificationId: verId,
                isUser: isUser,
                expiresIn: expiresIn,
                deviceId: deviceId,
                deviceSign: deviceSign
            )
        }
        throw ProviderError.apiMessage("验证码发送失败，请改用密码登录")
    }

    public func completeSmsLogin(phoneNumber: String, smsCode: String, challenge: GuangYaSmsChallenge) async throws -> (payload: GuangYaCredentialPayload, nickname: String) {
        let normalized = GuangYaConstants.normalizeAccount(phoneNumber)
        let verifyBody: [String: Any] = [
            "client_id": GuangYaConstants.clientId,
            "verification_id": challenge.verificationId,
            "verification_code": smsCode
        ]
        let verifyResp = try await http.send(
            url: GuangYaConstants.verificationVerifyURL,
            method: "POST",
            headers: accountHeaders(deviceId: challenge.deviceId, deviceSign: challenge.deviceSign, token: nil),
            body: try JSONSerialization.data(withJSONObject: verifyBody)
        )
        let verifyJson = try parseJSON(verifyResp)
        guard isSuccess(verifyJson) else {
            throw ProviderError.apiMessage("短信验证码错误或已过期")
        }
        let vNode = (verifyJson["data"] as? [String: Any]) ?? verifyJson
        let verificationToken = firstNonEmpty(stringValue(vNode["verification_token"]), stringValue(verifyJson["verification_token"]))
        guard !verificationToken.isEmpty else {
            throw ProviderError.apiMessage("短信验证码校验失败")
        }

        let authURL: String
        let authBody: [String: Any]
        if challenge.isUser {
            authURL = GuangYaConstants.signinURL
            authBody = [
                "client_id": GuangYaConstants.clientId,
                "username": normalized,
                "verification_code": smsCode,
                "verification_token": verificationToken
            ]
        } else {
            let digits = normalized.filter(\.isNumber)
            let masked = digits.count >= 7 ? "\(digits.prefix(3))****\(digits.suffix(4))" : "光鸭用户"
            authURL = GuangYaConstants.signupURL
            authBody = [
                "client_id": GuangYaConstants.clientId,
                "phone_number": normalized,
                "name": masked,
                "verification_code": smsCode,
                "verification_token": verificationToken
            ]
        }
        let authResp = try await http.send(
            url: authURL,
            method: "POST",
            headers: accountHeaders(deviceId: challenge.deviceId, deviceSign: challenge.deviceSign, token: nil),
            body: try JSONSerialization.data(withJSONObject: authBody)
        )
        let authJson = try parseJSON(authResp)
        guard isSuccess(authJson) else {
            let msg = firstNonEmpty(stringValue(authJson["msg"]), stringValue(authJson["message"]))
            throw ProviderError.apiMessage(msg.isEmpty ? "短信登录失败" : msg)
        }
        let payload = try parseTokens(authJson, deviceId: challenge.deviceId, deviceSign: challenge.deviceSign, account: normalized)
        let nick = await fetchNickname(credential: payload.encodedString()) ?? normalized
        return (payload, nick)
    }

    // MARK: - ShareResolveProvider

    public func fetchNickname(credential: String) async -> String? {
        guard let payload = GuangYaCredentialPayload.decode(from: credential) else { return nil }
        guard let resp = try? await http.send(
            url: GuangYaConstants.userMeURL,
            method: "GET",
            headers: accountHeaders(deviceId: payload.deviceId, deviceSign: payload.deviceSign, token: payload.accessToken)
        ),
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              isSuccess(json) else {
            return nil
        }
        let uid = firstNonEmpty(stringValue(json["sub"]), stringValue(json["user_id"]), stringValue(json["userId"]))
        guard !uid.isEmpty else { return nil }
        let nick = firstNonEmpty(
            stringValue(json["nickname"]),
            stringValue(json["nick_name"]),
            stringValue(json["name"]),
            stringValue(json["username"]),
            payload.account
        )
        return nick.isEmpty ? "光鸭用户" : nick
    }

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let code = (pwd ?? parsed.pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shareToken = try await getShareAccessToken(shareId: parsed.shareId, code: code)
        let title = await getShareSummary(shareId: parsed.shareId) ?? "光鸭云盘分享"
        return ShareSession(
            platform: .guangya,
            shareId: parsed.shareId,
            stoken: shareToken,
            title: title,
            originalLink: parsed.rawUrl,
            passcode: code.isEmpty ? nil : code
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var seen = Set<String>()
        var cursor: String? = nil

        for _ in 0..<50 {
            var body: [String: Any] = [
                "parentId": dirFid,
                "pageSize": GuangYaConstants.pageSize,
                "orderBy": 0,
                "sortType": 0,
                "accessToken": session.stoken
            ]
            if let cursor, !cursor.isEmpty {
                body["cursor"] = Int64(cursor) ?? cursor
            }
            let json = try await businessPost(url: GuangYaConstants.shareFilesURL, body: body, deviceId: nil, token: nil)
            try checkBusiness(json, fallback: "获取光鸭分享文件列表失败")
            guard let data = dataOf(json) else { break }
            let batch = parseFileList(listArray(data))
            var added = 0
            for f in batch where seen.insert(f.fid).inserted {
                all.append(f)
                added += 1
            }
            let next = stringValue(data["cursor"])
            let hasMore: Bool
            if let hm = data["hasMore"] as? Bool {
                hasMore = hm
            } else if data["total"] != nil {
                let total = int64Value(data["total"])
                let offset = Int64(next) ?? Int64(all.count)
                hasMore = total > 0 && offset < total
            } else {
                hasMore = batch.count >= GuangYaConstants.pageSize && !next.isEmpty
            }
            if !hasMore || next.isEmpty || added == 0 { break }
            cursor = next
        }
        return all
    }

    public func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        do {
            return try await fetchShareDirectDownload(file: file, shareToken: session.stoken)
        } catch is GuangYaRestrictedError {
            throw ProviderError.apiMessage("该分享未开启免登录下载（207），请先在「账号」页登录光鸭云盘后重试")
        }
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        // 1) 优先免转存直接取分享直链
        do {
            return try await fetchShareDirectDownload(file: file, shareToken: session.stoken)
        } catch is GuangYaRestrictedError {
            // 207 受限分享：已登录时走临时子目录转存 -> 个人盘取直链
        }

        guard let payload = GuangYaCredentialPayload.decode(from: credential) else {
            throw ProviderError.loginRequired(.guangya)
        }

        let tempRootId = try await ensureTempRootDir(payload: payload)
        let subDirId = try await createDir(
            parentId: tempRootId,
            name: "tr_\(Int64(Date().timeIntervalSince1970 * 1000))",
            payload: payload
        )

        do {
            try await restoreShare(
                shareToken: session.stoken,
                fileIds: [file.fid],
                parentId: subDirId,
                payload: payload
            )
            let files = try await listCloudFiles(parentId: subDirId, payload: payload)
            guard let saved = files.first(where: { !$0.isdir && $0.fname == file.fname }) ?? files.first(where: { !$0.isdir }) else {
                throw ProviderError.missingData("光鸭转存后未找到目标文件")
            }
            let link = try await fetchPersonalDownload(file: saved, payload: payload)
            return DownloadLink(
                fid: file.fid,
                filename: link.filename.isEmpty ? file.fname : link.filename,
                downloadUrl: link.downloadUrl,
                size: link.size > 0 ? link.size : file.fsize,
                cleanupDirFid: subDirId
            )
        } catch {
            await cleanupTempDir(dirFid: subDirId, credential: credential)
            throw error
        }
    }

    public func cleanupTempDir(dirFid: String, credential: String) async {
        guard !dirFid.isEmpty, let payload = GuangYaCredentialPayload.decode(from: credential) else { return }
        let body: [String: Any] = ["fileIds": [dirFid]]
        _ = try? await businessPost(url: GuangYaConstants.deleteFileURL, body: body, deviceId: payload.deviceId, token: payload.accessToken)
    }

    // MARK: - 内部业务 API

    private struct GuangYaRestrictedError: Error {}

    private func initCaptcha(deviceId: String, deviceSign: String, meta: [String: Any], action: String) async -> (token: String?, url: String?) {
        let body: [String: Any] = [
            "client_id": GuangYaConstants.clientId,
            "action": action,
            "device_id": deviceId,
            "captcha_token": "",
            "meta": meta
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let resp = try? await http.send(
                url: GuangYaConstants.captchaInitURL,
                method: "POST",
                headers: accountHeaders(deviceId: deviceId, deviceSign: deviceSign, token: nil),
                body: bodyData
              ),
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return (nil, nil)
        }
        let token = stringValue(json["captcha_token"])
        let url = stringValue(json["url"])
        return (token.isEmpty ? nil : token, url.isEmpty ? nil : url)
    }

    private func getShareSummary(shareId: String) async -> String? {
        guard let json = try? await businessPost(
            url: GuangYaConstants.shareSummaryURL,
            body: ["shareId": shareId],
            deviceId: nil,
            token: nil
        ), isSuccess(json) else { return nil }
        let data = dataOf(json) ?? json
        let title = firstNonEmpty(stringValue(data["title"]), stringValue(data["shareName"]))
        return title.isEmpty ? nil : title
    }

    private func getShareAccessToken(shareId: String, code: String) async throws -> String {
        let json = try await businessPost(
            url: GuangYaConstants.shareAccessTokenURL,
            body: ["shareId": shareId, "code": code],
            deviceId: nil,
            token: nil
        )
        try checkBusiness(json, fallback: "获取光鸭分享令牌失败")
        guard let data = dataOf(json) else {
            throw ProviderError.apiMessage("光鸭分享链接无效或已失效")
        }
        let token = firstNonEmpty(stringValue(data["accessToken"]), stringValue(data["access_token"]))
        guard !token.isEmpty else {
            throw ProviderError.apiMessage("光鸭分享链接无效或已失效")
        }
        return token
    }

    private func fetchShareDirectDownload(file: ShareFile, shareToken: String) async throws -> DownloadLink {
        let json = try await businessPost(
            url: GuangYaConstants.shareDownloadURL,
            body: ["fileId": file.fid, "accessToken": shareToken],
            deviceId: nil,
            token: nil
        )
        if stringValue(json["code"]) == "207" {
            throw GuangYaRestrictedError()
        }
        try checkBusiness(json, fallback: "获取光鸭下载直链失败")
        guard let data = dataOf(json) else {
            throw ProviderError.missingData("光鸭未返回有效下载地址")
        }
        let url = firstNonEmpty(
            stringValue(data["signedURL"]),
            stringValue(data["signedUrl"]),
            stringValue(data["downloadUrl"]),
            stringValue(data["download_url"]),
            stringValue(data["url"]),
            stringValue(data["cdnUrl"])
        )
        guard !url.isEmpty else {
            throw ProviderError.missingData("光鸭未返回有效下载地址")
        }
        let size = int64Value(data["size"]) > 0 ? int64Value(data["size"]) : file.fsize
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: url, size: size)
    }

    private func ensureTempRootDir(payload: GuangYaCredentialPayload) async throws -> String {
        let root = try await listCloudFiles(parentId: "", payload: payload)
        if let existing = root.first(where: { $0.isdir && $0.fname == GuangYaConstants.tempDirName }) {
            return existing.fid
        }
        return try await createDir(parentId: "", name: GuangYaConstants.tempDirName, payload: payload)
    }

    private func listCloudFiles(parentId: String, payload: GuangYaCredentialPayload) async throws -> [ShareFile] {
        let body: [String: Any] = [
            "parentId": parentId,
            "pageSize": GuangYaConstants.pageSize,
            "orderBy": 0,
            "sortType": 0,
            "page": 0
        ]
        let json = try await businessPost(url: GuangYaConstants.fileListURL, body: body, deviceId: payload.deviceId, token: payload.accessToken)
        try checkBusiness(json, fallback: "获取光鸭个人盘目录失败")
        guard let data = dataOf(json) else { return [] }
        return parseFileList(listArray(data))
    }

    private func createDir(parentId: String, name: String, payload: GuangYaCredentialPayload) async throws -> String {
        let body: [String: Any] = [
            "parentId": parentId,
            "dirName": name,
            "failIfNameExist": true
        ]
        let json = try await businessPost(url: GuangYaConstants.createDirURL, body: body, deviceId: payload.deviceId, token: payload.accessToken)
        try checkBusiness(json, fallback: "创建光鸭临时目录失败")
        guard let data = dataOf(json) else { throw ProviderError.missingData("创建光鸭临时目录失败") }
        let id = firstNonEmpty(stringValue(data["fileId"]), stringValue(data["id"]))
        guard !id.isEmpty else { throw ProviderError.missingData("创建光鸭临时目录失败") }
        return id
    }

    private func restoreShare(shareToken: String, fileIds: [String], parentId: String, payload: GuangYaCredentialPayload) async throws {
        let body: [String: Any] = [
            "accessToken": shareToken,
            "fileIds": fileIds,
            "parentId": parentId
        ]
        let json = try await businessPost(url: GuangYaConstants.restoreShareURL, body: body, deviceId: payload.deviceId, token: payload.accessToken)
        try checkBusiness(json, fallback: "光鸭转存分享失败")
        if let taskId = dataOf(json).map({ stringValue($0["taskId"]) }), !taskId.isEmpty {
            try await waitTask(taskId: taskId, payload: payload)
        }
    }

    private func waitTask(taskId: String, payload: GuangYaCredentialPayload) async throws {
        try? await Task.sleep(nanoseconds: 750_000_000)
        for _ in 0..<40 {
            let json = try await businessPost(
                url: GuangYaConstants.taskStatusURL,
                body: ["taskId": taskId],
                deviceId: payload.deviceId,
                token: payload.accessToken
            )
            try checkBusiness(json, fallback: "查询光鸭转存任务失败")
            if let data = dataOf(json) {
                let status = intValue(data["status"], default: 0)
                let detail = data["detail"] as? [String: Any]
                let detailCode = intValue(detail?["code"], default: 0)
                if status == 2 && detailCode == 0 { return }
                if status == 3 || (status == 2 && detailCode != 0) {
                    let msg = stringValue(detail?["msg"])
                    throw ProviderError.apiMessage(msg.isEmpty ? "光鸭转存操作失败" : msg)
                }
            }
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        throw ProviderError.apiMessage("光鸭转存超时，请稍后重试")
    }

    private func fetchPersonalDownload(file: ShareFile, payload: GuangYaCredentialPayload) async throws -> DownloadLink {
        let json = try await businessPost(
            url: GuangYaConstants.resDownloadURL,
            body: ["fileId": file.fid],
            deviceId: payload.deviceId,
            token: payload.accessToken
        )
        try checkBusiness(json, fallback: "获取光鸭个人盘直链失败")
        guard let data = dataOf(json) else { throw ProviderError.missingData("光鸭未返回有效下载地址") }
        let url = firstNonEmpty(
            stringValue(data["signedURL"]),
            stringValue(data["signedUrl"]),
            stringValue(data["downloadUrl"]),
            stringValue(data["download_url"]),
            stringValue(data["url"]),
            stringValue(data["cdnUrl"])
        )
        guard !url.isEmpty else { throw ProviderError.missingData("光鸭未返回有效下载地址") }
        let size = int64Value(data["size"]) > 0 ? int64Value(data["size"]) : file.fsize
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: url, size: size)
    }

    // MARK: - 请求构造与解析工具

    private func businessPost(url: String, body: [String: Any], deviceId: String?, token: String?) async throws -> [String: Any] {
        var headers: [String: String] = [
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "User-Agent": GuangYaConstants.webUA,
            "Origin": GuangYaConstants.webSite,
            "Referer": GuangYaConstants.downloadReferer,
            "dt": "4",
            "traceparent": GuangYaConstants.newTraceparent(),
            "did": (deviceId?.isEmpty == false) ? deviceId! : publicDeviceId
        ]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
        return try parseJSON(resp)
    }

    private func accountHeaders(deviceId: String, deviceSign: String, token: String?) -> [String: String] {
        let resolvedId = GuangYaConstants.deviceIdFromSign(deviceSign, fallback: deviceId)
        var headers: [String: String] = [
            "X-Client-Id": GuangYaConstants.clientId,
            "X-Client-Version": GuangYaConstants.clientVersion,
            "X-Device-Id": urlEncode(resolvedId),
            "X-Device-Model": GuangYaConstants.deviceModel,
            "X-Device-Name": GuangYaConstants.deviceName,
            "X-Device-Sign": urlEncode(deviceSign),
            "X-Os-Version": GuangYaConstants.osVersion,
            "X-Platform-Version": GuangYaConstants.platformVersion,
            "X-Protocol-Version": GuangYaConstants.protocolVersion,
            "X-Sdk-Version": GuangYaConstants.sdkVersion,
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Origin": GuangYaConstants.webSite,
            "Referer": GuangYaConstants.downloadReferer,
            "Accept-Language": "zh-CN",
            "User-Agent": GuangYaConstants.webUA
        ]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func parseTokens(_ json: [String: Any], deviceId: String, deviceSign: String, account: String) throws -> GuangYaCredentialPayload {
        let data = (json["data"] as? [String: Any]) ?? json
        let access = firstNonEmpty(stringValue(data["access_token"]), stringValue(data["accessToken"]))
        guard !access.isEmpty else { throw ProviderError.apiMessage("光鸭登录未返回访问令牌") }
        let refresh = firstNonEmpty(stringValue(data["refresh_token"]), stringValue(data["refreshToken"]))
        return GuangYaCredentialPayload(
            accessToken: access,
            refreshToken: refresh,
            deviceId: deviceId,
            deviceSign: deviceSign,
            account: account
        )
    }

    private func parseJSON(_ resp: HTTPResponseData) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        return obj
    }

    private func isSuccess(_ json: [String: Any]) -> Bool {
        if let ok = json["success"] as? Bool, !ok { return false }
        if !stringValue(json["error"]).isEmpty { return false }
        let code = stringValue(json["code"])
        return code.isEmpty || code == "0"
    }

    private func dataOf(_ json: [String: Any]) -> [String: Any]? {
        if let d = json["data"] as? [String: Any] { return d }
        return json.isEmpty ? nil : json
    }

    private func listArray(_ data: [String: Any]) -> [[String: Any]] {
        for key in ["list", "items", "files", "records", "content"] {
            if let arr = data[key] as? [[String: Any]] { return arr }
        }
        return []
    }

    private func parseFileList(_ list: [[String: Any]]) -> [ShareFile] {
        let thumbHeaders = [
            "User-Agent": GuangYaConstants.webUA,
            "Referer": GuangYaConstants.downloadReferer
        ]
        return list.compactMap { item in
            let fid = firstNonEmpty(
                stringValue(item["fileId"]), stringValue(item["file_id"]),
                stringValue(item["id"]), stringValue(item["resId"])
            )
            guard !fid.isEmpty else { return nil }
            let name = firstNonEmpty(
                stringValue(item["fileName"]), stringValue(item["name"]),
                stringValue(item["filename"]), stringValue(item["dirName"]), stringValue(item["title"])
            )
            let size = int64Value(item["fileSize"] ?? item["size"] ?? item["file_size"])
            let resType = stringValue(item["resType"])
            let isDir: Bool
            if resType == "2" { isDir = true }
            else if resType == "1" { isDir = false }
            else {
                isDir = (item["isDir"] as? Bool == true) ||
                    (item["isdir"] as? Bool == true) ||
                    (item["dir"] as? Bool == true) ||
                    !stringValue(item["dirName"]).isEmpty
            }
            let thumb = FileThumbnail.secure(url: stringValue(item["thumbnail"]), headers: thumbHeaders)
                ?? FileThumbnail.secure(url: stringValue(item["thumbnailUrl"]), headers: thumbHeaders)
                ?? FileThumbnail.secure(url: stringValue(item["cover"]), headers: thumbHeaders)
            return ShareFile(
                fid: fid,
                fname: name,
                fsize: isDir ? 0 : size,
                isdir: isDir,
                pdirFid: firstNonEmpty(stringValue(item["parentId"]), stringValue(item["parent_id"])),
                fidToken: "",
                modifyTime: firstNonEmpty(stringValue(item["updatedAt"]), stringValue(item["updateTime"])),
                thumbnail: thumb
            )
        }
    }

    private func checkBusiness(_ json: [String: Any], fallback: String) throws {
        if isSuccess(json) { return }
        let code = stringValue(json["code"])
        let serverMsg = firstNonEmpty(stringValue(json["msg"]), stringValue(json["message"]), stringValue(json["error_description"]))
        switch code {
        case "209": throw ProviderError.apiMessage("光鸭分享提取码错误")
        case "200", "201", "202": throw ProviderError.apiMessage("光鸭分享链接已失效或不存在")
        case "205", "206", "207", "504": throw ProviderError.apiMessage("该分享下载受限，请先登录光鸭云盘后重试")
        case "157": throw ProviderError.apiMessage("光鸭个人网盘空间不足")
        default:
            throw ProviderError.apiMessage(serverMsg.isEmpty ? "\(fallback)（错误码 \(code)）" : serverMsg)
        }
    }

    private func metaFor(_ account: String) -> [String: Any] {
        if account.hasPrefix("+") { return ["phone_number": account] }
        if account.contains("@") { return ["email": account] }
        return ["username": account]
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
