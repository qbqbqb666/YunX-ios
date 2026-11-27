//
//  QuarkProvider.swift
//  YunX
//
//  夸克网盘完整协议实现：
//  - 匿名/登录态列目录；
//  - 游客免登录直链（约 50MB 内，绑定响应 Set-Cookie 的 __pugs）；
//  - 登录态免转存直链（失败自动回退「唯一临时子目录 tr_* 转存 → 轮询 → 取链 → 下载后清理」）；
//  - Set-Cookie 自动合并续期 __puus/__pus。
//

import Foundation

public final class QuarkProvider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .quark

    private let http: HTTPClient
    private let lock = NSLock()
    private var guestPugs: String = ""
    public var onCookieRefreshed: (@Sendable (_ merged: String, _ requestCookie: String) -> Void)?

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - 账号校验与刷新

    public func fetchNickname(credential: String) async -> String? {
        guard !credential.isEmpty else { return nil }
        let headers = [
            "Cookie": credential,
            "User-Agent": QuarkConstants.apiUserAgent
        ]
        guard let resp = try? await http.send(url: QuarkConstants.accountInfoURL, headers: headers),
              resp.isSuccessful,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              (json["success"] as? Bool) == true,
              let data = json["data"] as? [String: Any],
              let nick = data["nickname"] as? String,
              !nick.isEmpty else {
            return nil
        }
        return nick
    }

    /// 剥离 __puus 访问 /config，触发服务端重新下发新鲜 __puus
    public func refreshSession(cookie: String) async -> String {
        guard !cookie.isEmpty else { return cookie }
        let headers = [
            "Cookie": CookieHelper.withoutPuus(cookie),
            "User-Agent": QuarkConstants.apiUserAgent,
            "Referer": QuarkConstants.downloadReferer
        ]
        guard let resp = try? await http.send(url: QuarkConstants.configURL, headers: headers) else {
            return cookie
        }
        let merged = CookieHelper.merge(original: cookie, setCookies: resp.setCookies)
        if merged != cookie {
            onCookieRefreshed?(merged, cookie)
        }
        return merged
    }

    // MARK: - 分享解析

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let effectivePwd = (pwd?.isEmpty == false ? pwd : parsed.pwd) ?? ""
        let payload: [String: Any] = [
            "pwd_id": parsed.shareId,
            "passcode": effectivePwd,
            "support_visit_limit_private_share": true
        ]
        let data = try await postJSONData(url: QuarkConstants.shareTokenURL, cookie: credential, body: payload)
        let stoken = data["stoken"] as? String ?? ""
        guard !stoken.isEmpty else {
            throw ProviderError.missingData("获取夸克分享凭证失败，请检查链接或提取码")
        }
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShareSession(
            platform: .quark,
            shareId: parsed.shareId,
            stoken: stoken,
            title: title.isEmpty ? "夸克分享" : title,
            originalLink: parsed.rawUrl,
            passcode: effectivePwd.isEmpty ? nil : effectivePwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        let encodedToken = session.stoken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.stoken
        let pdir = dirFid.isEmpty ? QuarkConstants.defaultPdirFid : dirFid

        for page in 1...100 {
            let url = "\(QuarkConstants.shareDetailURL)&pwd_id=\(session.shareId)&stoken=\(encodedToken)&pdir_fid=\(pdir)&ver=2&force=0&_page=\(page)&_size=100&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0&_fetch_total=1&_sort=file_type:asc,file_name:asc"
            var headers = [
                "User-Agent": QuarkConstants.apiUserAgent,
                "Origin": "https://pan.quark.cn",
                "Referer": "https://pan.quark.cn/"
            ]
            if !credential.isEmpty { headers["Cookie"] = credential }

            let data = try await getJSONData(url: url, headers: headers, originalCookie: credential)
            let list = data["list"] as? [[String: Any]] ?? []
            let batch = list.map { item in
                ShareFile(
                    fid: item["fid"] as? String ?? "",
                    fname: item["file_name"] as? String ?? "",
                    fsize: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    isdir: (item["dir"] as? Bool) ?? false,
                    pdirFid: item["pdir_fid"] as? String ?? pdir,
                    fidToken: item["share_fid_token"] as? String ?? "",
                    modifyTime: Self.stringValue(item["updated_at"])
                )
            }
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    // MARK: - 直链获取（登录态免转存 / 临时转存回退）

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard !credential.isEmpty else {
            throw ProviderError.loginRequired(.quark)
        }
        let freshCookie = await refreshSession(cookie: credential)

        if preferNoSave {
            if let direct = try? await fetchDownloadLinkWithoutSave(session: session, file: file, cookie: freshCookie) {
                return direct
            }
        }
        return try await fetchDownloadLinkViaTempTransfer(session: session, file: file, cookie: freshCookie)
    }

    private func fetchDownloadLinkWithoutSave(
        session: ShareSession,
        file: ShareFile,
        cookie: String
    ) async throws -> DownloadLink {
        let payload: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.fidToken],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "speedup_session": "",
            "token": ""
        ]
        return try await requestDownloadLink(cookie: cookie, payload: payload, isGuest: false)
    }

    private func fetchDownloadLinkViaTempTransfer(
        session: ShareSession,
        file: ShareFile,
        cookie: String
    ) async throws -> DownloadLink {
        let baseDir = try await ensureTempDir(cookie: cookie)
        let subName = "tr_\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...999999))"
        let subDirFid = try await createFolder(name: subName, parentFid: baseDir, cookie: cookie)
        let taskId = try await saveShareFile(session: session, file: file, toDirFid: subDirFid, cookie: cookie)
        let savedFid = try await pollTransferTask(taskId: taskId, cookie: cookie)
        let link = try await requestDownloadLink(cookie: cookie, payload: ["fids": [savedFid]], isGuest: false)
        return link.withCleanupDirFid(subDirFid)
    }

    // MARK: - 游客免登录直链（约 50MB 内）

    public func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let payload: [String: Any] = [
            "fids": [file.fid],
            "fids_token": [file.fidToken],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "speedup_session": "",
            "token": ""
        ]
        let existingPugs = currentGuestPugs()
        return try await requestDownloadLink(cookie: existingPugs, payload: payload, isGuest: true)
    }

    public func cleanupTempDir(dirFid: String, credential: String) async {
        guard !dirFid.isEmpty, !credential.isEmpty else { return }
        let payload: [String: Any] = [
            "action_type": 2,
            "filelist": [dirFid],
            "exclude_fids": []
        ]
        _ = try? await postJSONData(url: QuarkConstants.deleteURL, cookie: credential, body: payload)
    }

    // MARK: - 内部请求封装

    private func requestDownloadLink(cookie: String, payload: [String: Any], isGuest: Bool) async throws -> DownloadLink {
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        var headers = [
            "User-Agent": QuarkConstants.apiUserAgent,
            "Content-Type": "application/json"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        let resp = try await http.send(url: QuarkConstants.downloadURL, method: "POST", headers: headers, body: bodyData)
        let responsePugs = isGuest ? CookieHelper.extractPugs(from: resp.setCookies) : nil
        if let responsePugs {
            setGuestPugs(responsePugs)
        } else if !isGuest && !cookie.isEmpty {
            let merged = CookieHelper.merge(original: cookie, setCookies: resp.setCookies)
            if merged != cookie { onCookieRefreshed?(merged, cookie) }
        }

        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        let status = (json["status"] as? NSNumber)?.intValue ?? 0
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        if status != 200 && code != 0 {
            let serverMsg = (json["message"] as? String) ?? ""
            if isGuest {
                switch code {
                case 23018:
                    throw ProviderError.apiMessage("该文件超出夸克游客免登录下载上限（约 50MB），请先在「账号」页登录夸克", code: code)
                case 31001:
                    throw ProviderError.apiMessage("该分享需要登录夸克账号后才能下载", code: code)
                default:
                    throw ProviderError.apiMessage(serverMsg.isEmpty ? "获取夸克游客直链失败" : serverMsg, code: code)
                }
            }
            if code == 31001 {
                throw ProviderError.apiMessage("夸克登录状态已失效，请重新登录", code: code)
            }
            throw ProviderError.apiMessage(serverMsg.isEmpty ? "获取夸克下载直链失败" : serverMsg, code: code)
        }

        guard let list = json["data"] as? [[String: Any]], let first = list.first else {
            throw ProviderError.missingData("夸克响应缺少直链数据")
        }
        let downloadUrl = first["download_url"] as? String ?? ""
        guard !downloadUrl.isEmpty else {
            throw ProviderError.missingData("未能提取到有效下载直链")
        }
        let fname = (first["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (first["filename"] as? String) ?? ""
        return DownloadLink(
            fid: first["fid"] as? String ?? "",
            filename: fname,
            downloadUrl: downloadUrl,
            size: (first["size"] as? NSNumber)?.int64Value ?? 0,
            guestCookie: isGuest ? (responsePugs ?? currentGuestPugs()) : ""
        )
    }

    private func ensureTempDir(cookie: String) async throws -> String {
        let url = "\(QuarkConstants.fileURL)&pdir_fid=\(QuarkConstants.defaultPdirFid)&page=1&size=100"
        let headers = ["Cookie": cookie, "User-Agent": QuarkConstants.apiUserAgent]
        let data = try await getJSONData(url: url, headers: headers, originalCookie: cookie)
        let list = data["list"] as? [[String: Any]] ?? []
        for item in list {
            let isDir = (item["dir"] as? Bool) ?? ((item["isdir"] as? NSNumber)?.intValue == 1)
            let name = (item["file_name"] as? String) ?? (item["fname"] as? String) ?? ""
            if isDir && name == QuarkConstants.tempDirName, let fid = item["fid"] as? String, !fid.isEmpty {
                return fid
            }
        }
        return try await createFolder(name: QuarkConstants.tempDirName, parentFid: QuarkConstants.defaultPdirFid, cookie: cookie)
    }

    private func createFolder(name: String, parentFid: String, cookie: String) async throws -> String {
        let payload: [String: Any] = [
            "pdir_fid": parentFid,
            "file_name": name,
            "dir_path": "",
            "dir_init_lock": false
        ]
        let data = try await postJSONData(url: QuarkConstants.fileURL, cookie: cookie, body: payload)
        guard let fid = data["fid"] as? String, !fid.isEmpty else {
            throw ProviderError.missingData("创建夸克临时目录失败")
        }
        return fid
    }

    private func saveShareFile(session: ShareSession, file: ShareFile, toDirFid: String, cookie: String) async throws -> String {
        let payload: [String: Any] = [
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "pdir_fid": file.pdirFid,
            "to_pdir_fid": toDirFid,
            "fid_list": [file.fid],
            "fid_token_list": [file.fidToken],
            "scene": "link"
        ]
        let data = try await postJSONData(url: QuarkConstants.saveURL, cookie: cookie, body: payload)
        guard let taskId = data["task_id"] as? String, !taskId.isEmpty else {
            throw ProviderError.missingData("夸克转存任务创建失败")
        }
        return taskId
    }

    private func pollTransferTask(taskId: String, cookie: String) async throws -> String {
        let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId
        let url = "\(QuarkConstants.taskURL)&task_id=\(encoded)&retry_index=0"
        let headers = ["Cookie": cookie, "User-Agent": QuarkConstants.apiUserAgent]
        for _ in 0..<12 {
            if let data = try? await getJSONData(url: url, headers: headers, originalCookie: cookie) {
                let finishedAt = (data["finished_at"] as? NSNumber)?.int64Value ?? 0
                let status = (data["status"] as? NSNumber)?.intValue ?? 0
                let taskStatus = (data["task_status"] as? NSNumber)?.intValue ?? 0
                if finishedAt > 0 || status == 2 || taskStatus == 2 {
                    if let saveAs = data["save_as"] as? [String: Any],
                       let fids = saveAs["save_as_top_fids"] as? [String],
                       let first = fids.first, !first.isEmpty {
                        return first
                    }
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw ProviderError.missingData("夸克临时转存轮询超时")
    }

    private func getJSONData(url: String, headers: [String: String], originalCookie: String) async throws -> [String: Any] {
        let resp = try await http.send(url: url, method: "GET", headers: headers)
        return try unwrapEnvelope(resp: resp, originalCookie: originalCookie)
    }

    private func postJSONData(url: String, cookie: String, body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var headers = [
            "User-Agent": QuarkConstants.apiUserAgent,
            "Content-Type": "application/json"
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let resp = try await http.send(url: url, method: "POST", headers: headers, body: bodyData)
        return try unwrapEnvelope(resp: resp, originalCookie: cookie)
    }

    private func unwrapEnvelope(resp: HTTPResponseData, originalCookie: String) throws -> [String: Any] {
        if !originalCookie.isEmpty {
            let merged = CookieHelper.merge(original: originalCookie, setCookies: resp.setCookies)
            if merged != originalCookie { onCookieRefreshed?(merged, originalCookie) }
        }
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        let status = (json["status"] as? NSNumber)?.intValue ?? 0
        if status != 200 {
            let msg = (json["message"] as? String) ?? "夸克请求失败"
            let code = (json["code"] as? NSNumber)?.intValue
            throw ProviderError.apiMessage(msg, code: code)
        }
        guard let data = json["data"] as? [String: Any] else {
            throw ProviderError.missingData("夸克响应缺少 data 字段")
        }
        return data
    }

    private func currentGuestPugs() -> String {
        lock.lock()
        defer { lock.unlock() }
        return guestPugs
    }

    private func setGuestPugs(_ val: String) {
        lock.lock()
        guestPugs = val
        lock.unlock()
    }

    private static func stringValue(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
