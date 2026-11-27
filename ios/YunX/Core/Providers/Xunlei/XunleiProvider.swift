//
//  XunleiProvider.swift
//  YunX
//
//  迅雷网盘解析与认证引擎：
//  - 支持原生账号密码登录、短信验证码登录、OAuth2 refresh_token 自动续期；
//  - 分享列目录支持匿名访问（无 Authorization）；
//  - 登录态取直链走「临时转存 -> files/{id} 提取直链 -> 立即删除临时文件」，下载并发在 SettingsStore 中固定 8 线程。
//

import Foundation

public struct XunleiLoginStep: Sendable {
    public let needSms: Bool
    public let smsCreditKey: String
    public let smsToken: String
    public let sessionId: String
    public let nickname: String
    public let userID: String
    public let reviewUrl: String
    public let message: String
}

public final class XunleiProvider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .xunlei
    private let http: HTTPClient

    /// 刷新 access_token / captcha_token 后回调上层落库
    public var onCredentialRefreshed: ((_ newEncoded: String, _ oldRaw: String) -> Void)?

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - 原生登录 / 短信登录 / 换取 Token

    public func loginWithPassword(username: String, password: String, deviceId: String = XunleiSigner.deviceId()) async throws -> XunleiLoginStep {
        var body = baseLoginBody(clientVersion: "25.0.5.25", sdkVersion: "513006")
        body["userName"] = username
        body["passWord"] = password
        body["verifyKey"] = ""
        body["verifyCode"] = ""
        body["isMd5Pwd"] = "0"
        let resp = try await http.send(
            url: XunleiConstants.loginURL,
            method: "POST",
            headers: [
                "User-Agent": "android-ok-http-client/xl-acc-sdk/version-5.1.3.513006",
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let json = (try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
        return parseLoginResponse(json)
    }

    public func sendSms(mobile: String) async throws -> XunleiLoginStep {
        var body = baseLoginBody(clientVersion: "8.31.0.9726", sdkVersion: "231500")
        body["mobile"] = mobile
        body["register"] = "0"
        let resp = try await http.send(
            url: XunleiConstants.sendSmsURL,
            method: "POST",
            headers: [
                "User-Agent": "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000",
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let json = (try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
        return XunleiLoginStep(
            needSms: true,
            smsCreditKey: stringValue(json["creditkey"]),
            smsToken: stringValue(json["token"]),
            sessionId: "",
            nickname: "",
            userID: "",
            reviewUrl: "",
            message: stringValue(json["errorDesc"]).isEmpty ? "短信验证码已发送" : stringValue(json["errorDesc"])
        )
    }

    public func smsLogin(mobile: String, smsCode: String, creditKey: String, smsToken: String) async throws -> XunleiLoginStep {
        var body = baseLoginBody(clientVersion: "8.31.0.9726", sdkVersion: "231500", creditKey: creditKey)
        body["mobile"] = mobile
        body["smsCode"] = smsCode
        body["token"] = smsToken
        body["register"] = "0"
        let resp = try await http.send(
            url: XunleiConstants.smsLoginURL,
            method: "POST",
            headers: [
                "User-Agent": "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000",
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let json = (try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]) ?? [:]
        return parseLoginResponse(json)
    }

    public func initCaptcha(
        deviceId: String,
        username: String = "",
        action: String = "POST:/auth/signin/token",
        userId: String = ""
    ) async -> String? {
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let sign = XunleiSigner.buildCaptchaSign(deviceId: deviceId, timestampMs: ts)
        let body: [String: Any] = [
            "action": action,
            "captcha_token": "",
            "client_id": XunleiConstants.appClientId,
            "device_id": deviceId,
            "meta": [
                "username": username,
                "client_version": XunleiConstants.appClientVersion,
                "package_name": XunleiConstants.appPackageName,
                "timestamp": ts,
                "captcha_sign": sign,
                "user_id": userId
            ],
            "redirect_uri": "xlaccsdk01://xunlei.com/callback?state=harbor"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let resp = try? await http.send(
                url: XunleiConstants.captchaInitURL,
                method: "POST",
                headers: [
                    "User-Agent": XunleiConstants.appUA,
                    "Accept": "application/json;charset=UTF-8",
                    "Content-Type": "application/json",
                    "X-Client-Id": XunleiConstants.appClientId,
                    "X-Device-Id": deviceId,
                    "X-Client-Version": XunleiConstants.appClientVersion
                ],
                body: bodyData
              ),
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return nil
        }
        let token = stringValue(json["captcha_token"])
        return token.isEmpty ? nil : token
    }

    public func exchangeToken(sessionId: String, deviceId: String, userId: String = "", username: String = "") async throws -> XunleiCredentialPayload {
        let captcha = await initCaptcha(deviceId: deviceId, username: username, action: "POST:/auth/signin/token", userId: userId) ?? ""
        let body: [String: Any] = [
            "client_id": XunleiConstants.appClientId,
            "client_secret": XunleiConstants.appClientSecret,
            "provider": "access_end_point_token",
            "signin_token": sessionId
        ]
        var headers: [String: String] = [
            "User-Agent": XunleiConstants.appUA,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XunleiConstants.appClientId,
            "X-Device-Id": deviceId,
            "X-Client-Version": XunleiConstants.appClientVersion
        ]
        if !captcha.isEmpty { headers["X-Captcha-Token"] = captcha }
        let resp = try await http.send(
            url: XunleiConstants.tokenURL,
            method: "POST",
            headers: headers,
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        let at = stringValue(json["access_token"]).isEmpty ? stringValue(json["accessToken"]) : stringValue(json["access_token"])
        let rt = stringValue(json["refresh_token"]).isEmpty ? stringValue(json["refreshToken"]) : stringValue(json["refresh_token"])
        guard !at.isEmpty else {
            let errDesc = stringValue(json["error_description"]).isEmpty ? stringValue(json["error"]) : stringValue(json["error_description"])
            throw ProviderError.apiMessage(errDesc.isEmpty ? "迅雷换取访问令牌失败" : errDesc)
        }
        return XunleiCredentialPayload(
            accessToken: at,
            refreshToken: rt,
            deviceId: deviceId,
            captchaToken: captcha,
            authType: ""
        )
    }

    public func refreshToken(_ payload: XunleiCredentialPayload) async -> XunleiCredentialPayload? {
        guard !payload.refreshToken.isEmpty else { return nil }
        let deviceId = payload.deviceId.isEmpty ? XunleiSigner.deviceId() : payload.deviceId
        let isWeb = payload.authType == XunleiConstants.webAuthType

        let resp: HTTPResponseData
        do {
            if isWeb {
                let body: [String: Any] = [
                    "grant_type": "refresh_token",
                    "client_id": XunleiConstants.webClientId,
                    "refresh_token": payload.refreshToken
                ]
                resp = try await http.send(
                    url: XunleiConstants.refreshURL,
                    method: "POST",
                    headers: [
                        "Content-Type": "application/json",
                        "X-Device-Id": deviceId,
                        "X-Client-Id": XunleiConstants.webClientId,
                        "Origin": "https://pan.xunlei.com",
                        "Referer": "https://pan.xunlei.com/",
                        "User-Agent": XunleiConstants.desktopUA
                    ],
                    body: try JSONSerialization.data(withJSONObject: body)
                )
            } else {
                let body = "grant_type=refresh_token&client_id=\(XunleiConstants.appClientId)" +
                    "&client_secret=\(XunleiConstants.appClientSecret)&refresh_token=\(urlEncode(payload.refreshToken))"
                resp = try await http.send(
                    url: XunleiConstants.refreshURL,
                    method: "POST",
                    headers: [
                        "Content-Type": "application/x-www-form-urlencoded",
                        "X-Device-Id": deviceId
                    ],
                    body: body.data(using: .utf8)
                )
            }
        } catch {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else { return nil }
        let at = stringValue(json["access_token"]).isEmpty ? stringValue(json["accessToken"]) : stringValue(json["access_token"])
        let rt = stringValue(json["refresh_token"]).isEmpty ? payload.refreshToken : stringValue(json["refresh_token"])
        guard !at.isEmpty else { return nil }
        return XunleiCredentialPayload(
            accessToken: at,
            refreshToken: rt,
            deviceId: deviceId,
            captchaToken: payload.captchaToken,
            authType: payload.authType
        )
    }

    // MARK: - ShareResolveProvider

    public func fetchNickname(credential: String) async -> String? {
        guard let payload = XunleiCredentialPayload.decode(from: credential) else { return nil }
        let deviceId = payload.deviceId.isEmpty ? XunleiSigner.deviceId() : payload.deviceId
        guard let resp = try? await http.send(
            url: XunleiConstants.aboutURL,
            headers: panHeaders(accessToken: payload.accessToken, deviceId: deviceId, captchaToken: payload.captchaToken)
        ), resp.isSuccessful,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              (json["data"] != nil || stringValue(json["kind"]) == "drive#about") else {
            return nil
        }
        let sub = XunleiSigner.jwtSub(payload.accessToken)
        return sub.isEmpty ? "迅雷用户" : "迅雷用户 \(sub.prefix(6))"
    }

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let passCode = (pwd ?? parsed.pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let activePayload = await prepareValidPayload(rawCredential: credential)
        let res = try await fetchShareRoot(shareId: parsed.shareId, passCode: passCode, payload: activePayload)
        return ShareSession(
            platform: .xunlei,
            shareId: parsed.shareId,
            stoken: res.passCodeToken,
            title: res.title.isEmpty ? "迅雷分享" : res.title,
            originalLink: parsed.rawUrl,
            passcode: passCode.isEmpty ? nil : passCode
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let activePayload = await prepareValidPayload(rawCredential: credential)
        if dirFid.isEmpty || dirFid == "0" {
            let res = try await fetchShareRoot(shareId: session.shareId, passCode: session.passcode ?? "", payload: activePayload)
            var all = res.files
            var next = res.nextPageToken
            for _ in 0..<20 where !next.isEmpty {
                let more = try await fetchShareRoot(shareId: session.shareId, passCode: session.passcode ?? "", payload: activePayload, pageToken: next)
                all.append(contentsOf: more.files)
                next = more.nextPageToken
            }
            return all
        } else {
            var all: [ShareFile] = []
            var next = ""
            for _ in 0..<20 {
                let page = try await fetchShareDetail(
                    shareId: session.shareId,
                    parentId: dirFid,
                    passCodeToken: session.stoken,
                    payload: activePayload,
                    pageToken: next
                )
                all.append(contentsOf: page.files)
                if page.nextPageToken.isEmpty { break }
                next = page.nextPageToken
            }
            return all
        }
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard var payload = await prepareValidPayload(rawCredential: credential) else {
            throw ProviderError.loginRequired(.xunlei)
        }
        let deviceId = payload.deviceId.isEmpty ? XunleiSigner.deviceId() : payload.deviceId
        if payload.captchaToken.isEmpty {
            payload.captchaToken = await initCaptcha(
                deviceId: deviceId,
                action: "POST:/drive/v1/share/restore",
                userId: XunleiSigner.jwtSub(payload.accessToken)
            ) ?? ""
        }

        // 1) 确保临时转存目录存在
        let tempDirId = try await ensureTempDir(payload: payload)

        // 2) 转存单文件到临时目录
        let restoredFileIds = try await restoreShare(
            shareId: session.shareId,
            passCodeToken: session.stoken,
            fileIds: [file.fid],
            parentId: tempDirId,
            payload: payload
        )
        let targetId: String
        if let first = restoredFileIds.first, !first.isEmpty {
            targetId = first
        } else {
            let listed = try await listPersonalFiles(parentId: tempDirId, payload: payload)
            guard let matched = listed.first(where: { !$0.isdir && $0.fname == file.fname }) ?? listed.first(where: { !$0.isdir }) else {
                throw ProviderError.missingData("迅雷转存后未找到目标文件")
            }
            targetId = matched.fid
        }

        // 3) 查询文件详情获取直链，随即清理临时文件
        let finalPayload = payload
        defer {
            Task.detached { [self, finalPayload, targetId] in
                await self.deleteFiles(ids: [targetId], payload: finalPayload)
            }
        }
        let link = try await getFileDownloadLink(fileId: targetId, fallbackName: file.fname, fallbackSize: file.fsize, payload: finalPayload)
        return link
    }

    // MARK: - 内部 Pan API

    private struct SharePage {
        let title: String
        let passCodeToken: String
        let files: [ShareFile]
        let nextPageToken: String
    }

    private func prepareValidPayload(rawCredential: String) async -> XunleiCredentialPayload? {
        guard let payload = XunleiCredentialPayload.decode(from: rawCredential) else { return nil }
        let exp = XunleiSigner.jwtExp(payload.accessToken)
        let now = Int64(Date().timeIntervalSince1970)
        if exp > 0 && exp <= now + 300, !payload.refreshToken.isEmpty {
            if let refreshed = await refreshToken(payload) {
                onCredentialRefreshed?(refreshed.encodedString(), rawCredential)
                return refreshed
            }
        }
        return payload
    }

    private func fetchShareRoot(
        shareId: String,
        passCode: String,
        payload: XunleiCredentialPayload?,
        pageToken: String = ""
    ) async throws -> SharePage {
        var url = "\(XunleiConstants.shareURL)?share_id=\(urlEncode(shareId))&pass_code=\(urlEncode(passCode))" +
            "&limit=100&thumbnail_size=SIZE_SMALL"
        if !pageToken.isEmpty { url += "&page_token=\(urlEncode(pageToken))" }

        let json = try await panRequestJSON(url: url, method: "GET", body: nil, action: "GET:/drive/v1/share", payload: payload)
        let title = stringValue(json["title"])
        let token = stringValue(json["pass_code_token"])
        let files = parseFiles(json["files"] as? [[String: Any]] ?? [])
        let next = stringValue(json["next_page_token"])
        return SharePage(title: title, passCodeToken: token, files: files, nextPageToken: next)
    }

    private func fetchShareDetail(
        shareId: String,
        parentId: String,
        passCodeToken: String,
        payload: XunleiCredentialPayload?,
        pageToken: String = ""
    ) async throws -> SharePage {
        var url = "\(XunleiConstants.shareDetailURL)?share_id=\(urlEncode(shareId))" +
            "&parent_id=\(urlEncode(parentId))&pass_code_token=\(urlEncode(passCodeToken))" +
            "&limit=100&thumbnail_size=SIZE_SMALL"
        if !pageToken.isEmpty { url += "&page_token=\(urlEncode(pageToken))" }

        let json = try await panRequestJSON(url: url, method: "GET", body: nil, action: "GET:/drive/v1/share/detail", payload: payload)
        let files = parseFiles(json["files"] as? [[String: Any]] ?? [])
        let next = stringValue(json["next_page_token"])
        return SharePage(title: "", passCodeToken: passCodeToken, files: files, nextPageToken: next)
    }

    private func ensureTempDir(payload: XunleiCredentialPayload) async throws -> String {
        let rootFiles = try await listPersonalFiles(parentId: "", payload: payload)
        if let existing = rootFiles.first(where: { $0.isdir && $0.fname == XunleiConstants.tempDirName }) {
            return existing.fid
        }
        let body: [String: Any] = [
            "kind": "drive#folder",
            "name": XunleiConstants.tempDirName,
            "parent_id": "",
            "space": ""
        ]
        let json = try await panRequestJSON(
            url: XunleiConstants.filesURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/files",
            payload: payload
        )
        let id = stringValue(json["id"]).isEmpty
            ? stringValue((json["file"] as? [String: Any])?["id"])
            : stringValue(json["id"])
        guard !id.isEmpty else {
            throw ProviderError.missingData("创建迅雷临时目录失败")
        }
        return id
    }

    private func listPersonalFiles(parentId: String, payload: XunleiCredentialPayload) async throws -> [ShareFile] {
        let filters = urlEncode("{\"trashed\":{\"eq\":false}}")
        let url = "\(XunleiConstants.filesURL)?parent_id=\(urlEncode(parentId))&limit=100&with_audit=true&filters=\(filters)&thumbnail_size=SIZE_SMALL"
        let json = try await panRequestJSON(url: url, method: "GET", body: nil, action: "GET:/drive/v1/files", payload: payload)
        return parseFiles(json["files"] as? [[String: Any]] ?? [])
    }

    private func restoreShare(
        shareId: String,
        passCodeToken: String,
        fileIds: [String],
        parentId: String,
        payload: XunleiCredentialPayload
    ) async throws -> [String] {
        let body: [String: Any] = [
            "share_id": shareId,
            "pass_code_token": passCodeToken,
            "file_ids": fileIds,
            "parent_id": parentId,
            "specify_parent_id": true
        ]
        let json = try await panRequestJSON(
            url: XunleiConstants.restoreURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/share/restore",
            payload: payload
        )
        if let traceIds = json["trace_file_ids"] as? [String], !traceIds.isEmpty {
            return traceIds
        }
        let taskId = stringValue(json["restore_task_id"]).isEmpty ? stringValue(json["task_id"]) : stringValue(json["restore_task_id"])
        if !taskId.isEmpty {
            return await pollRestoreTask(taskId: taskId, payload: payload)
        }
        return []
    }

    private func pollRestoreTask(taskId: String, payload: XunleiCredentialPayload) async -> [String] {
        let url = "\(XunleiConstants.tasksURL)/\(urlEncode(taskId))?type=share"
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let json = try? await panRequestJSON(url: url, method: "GET", body: nil, action: "GET:/drive/v1/tasks", payload: payload) {
                let phase = stringValue(json["phase"])
                if phase == "PHASE_TYPE_COMPLETE" {
                    if let params = json["params"] as? [String: Any],
                       let traceStr = params["trace_file_ids"] as? String {
                        return traceStr.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                    }
                    return []
                }
                if phase == "PHASE_TYPE_ERROR" { return [] }
            }
        }
        return []
    }

    private func getFileDownloadLink(fileId: String, fallbackName: String, fallbackSize: Int64, payload: XunleiCredentialPayload) async throws -> DownloadLink {
        let url = "\(XunleiConstants.filesURL)/\(urlEncode(fileId))?space="
        let json = try await panRequestJSON(url: url, method: "GET", body: nil, action: "GET:/drive/v1/files", payload: payload)
        let links = json["links"] as? [String: Any]
        let octet = links?["application/octet-stream"] as? [String: Any]
        var dlUrl = stringValue(octet?["url"])
        if dlUrl.isEmpty {
            dlUrl = stringValue(json["web_content_link"])
        }
        guard !dlUrl.isEmpty else {
            throw ProviderError.missingData("迅雷未返回有效下载地址")
        }
        let name = stringValue(json["name"]).isEmpty ? fallbackName : stringValue(json["name"])
        let size = int64Value(json["size"]) > 0 ? int64Value(json["size"]) : fallbackSize
        return DownloadLink(fid: fileId, filename: name, downloadUrl: dlUrl, size: size)
    }

    private func deleteFiles(ids: [String], payload: XunleiCredentialPayload) async {
        guard !ids.isEmpty else { return }
        let body: [String: Any] = ["ids": ids, "space": ""]
        _ = try? await panRequestJSON(
            url: XunleiConstants.deleteURL,
            method: "POST",
            body: body,
            action: "POST:/drive/v1/files:batchDelete",
            payload: payload
        )
    }

    /// 统一 Pan 请求：支持匿名（不带 Authorization）以及 captcha_invalid 自动重签重试 1 次
    private func panRequestJSON(
        url: String,
        method: String,
        body: [String: Any]?,
        action: String,
        payload: XunleiCredentialPayload?
    ) async throws -> [String: Any] {
        let deviceId = (payload?.deviceId.isEmpty == false) ? payload!.deviceId : XunleiSigner.deviceId()
        var captcha = payload?.captchaToken ?? ""
        let accessToken = payload?.accessToken ?? ""
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }

        for attempt in 0..<2 {
            let headers = panHeaders(accessToken: accessToken, deviceId: deviceId, captchaToken: captcha)
            let resp = try await http.send(url: url, method: method, headers: headers, body: bodyData)
            guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
                throw HTTPClientError.invalidJSON(resp.statusCode)
            }
            let errCode = stringValue(json["error"]).lowercased()
            if (errCode == "captcha_invalid" || errCode == "captcha_required") && attempt == 0 {
                let userId = accessToken.isEmpty ? "" : XunleiSigner.jwtSub(accessToken)
                if let fresh = await initCaptcha(deviceId: deviceId, action: action, userId: userId) {
                    captcha = fresh
                    continue
                }
            }
            if !resp.isSuccessful || (!errCode.isEmpty && errCode != "ok") {
                let desc = stringValue(json["error_description"]).isEmpty ? stringValue(json["message"]) : stringValue(json["error_description"])
                if errCode == "unauthenticated" || resp.statusCode == 401 {
                    throw ProviderError.apiMessage("迅雷登录已过期，请在「账号」页重新登录")
                }
                throw ProviderError.apiMessage(desc.isEmpty ? "迅雷接口错误：\(errCode)" : desc)
            }
            return json
        }
        throw ProviderError.missingData("迅雷请求失败")
    }

    private func panHeaders(accessToken: String, deviceId: String, captchaToken: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": XunleiConstants.appUA,
            "Accept": "application/json;charset=UTF-8",
            "Content-Type": "application/json",
            "X-Client-Id": XunleiConstants.appClientId,
            "X-Device-Id": deviceId,
            "X-Client-Version": XunleiConstants.appClientVersion
        ]
        if !accessToken.isEmpty {
            h["Authorization"] = "Bearer \(accessToken)"
        }
        if !captchaToken.isEmpty {
            h["X-Captcha-Token"] = captchaToken
        }
        return h
    }

    private func baseLoginBody(clientVersion: String, sdkVersion: String, creditKey: String = "") -> [String: Any] {
        [
            "protocolVersion": "301",
            "sequenceNo": String(Int.random(in: 10_000_000...99_999_999)),
            "platformVersion": "10",
            "isCompressed": "0",
            "appid": "40",
            "clientVersion": clientVersion,
            "peerID": XunleiSigner.peerId(),
            "appName": "ANDROID-com.xunlei.downloadprovider",
            "sdkVersion": sdkVersion,
            "devicesign": XunleiSigner.deviceSign(),
            "netWorkType": "WIFI",
            "providerName": "NONE",
            "deviceModel": "M2004J7AC",
            "deviceName": "Xiaomi_M2004j7ac",
            "OSVersion": "12",
            "creditkey": creditKey,
            "hl": "zh-CN"
        ]
    }

    private func parseLoginResponse(_ json: [String: Any]) -> XunleiLoginStep {
        let errorCode = stringValue(json["errorCode"])
        let error = stringValue(json["error"])
        if errorCode == "0" || error == "success" {
            return XunleiLoginStep(
                needSms: false,
                smsCreditKey: "",
                smsToken: "",
                sessionId: stringValue(json["sessionID"]),
                nickname: stringValue(json["nickName"]),
                userID: stringValue(json["userID"]),
                reviewUrl: "",
                message: "登录成功"
            )
        }
        let verifyType = stringValue(json["verifyType"])
        let needSms = error == "review_panel" || errorCode == "1007" || !verifyType.isEmpty
        let desc = stringValue(json["errorDesc"]).isEmpty ? stringValue(json["error_description"]) : stringValue(json["errorDesc"])
        return XunleiLoginStep(
            needSms: needSms,
            smsCreditKey: "",
            smsToken: "",
            sessionId: "",
            nickname: "",
            userID: "",
            reviewUrl: stringValue(json["reviewurl"]),
            message: desc.isEmpty ? "登录失败，请改用短信验证码登录" : desc
        )
    }

    private func parseFiles(_ list: [[String: Any]]) -> [ShareFile] {
        list.compactMap { item in
            let id = stringValue(item["id"])
            guard !id.isEmpty else { return nil }
            let kind = stringValue(item["kind"])
            let isDir = kind == "drive#folder"
            let thumbUrl = stringValue(item["thumbnail_link"])
            return ShareFile(
                fid: id,
                fname: stringValue(item["name"]),
                fsize: isDir ? 0 : int64Value(item["size"]),
                isdir: isDir,
                pdirFid: stringValue(item["parent_id"]),
                fidToken: "",
                modifyTime: stringValue(item["modified_time"]),
                thumbnail: FileThumbnail.secure(url: thumbUrl)
            )
        }
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

    private func int64Value(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return 0
    }
}
