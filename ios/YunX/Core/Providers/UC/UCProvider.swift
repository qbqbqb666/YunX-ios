//
//  UCProvider.swift
//  YunX
//
//  UC 网盘完整协议实现：
//  - 匿名/登录态列目录（transfer_share/detail，返回的 share_fid_token 与 stoken 绑定）；
//  - 游客免登录直链（不限大小，携带当次响应 __pugs + uc-cloud-drive UA）；
//  - 登录态免转存直链（视频优先尝试 video_preview 原画直链绕过宣传片替换）；
//  - Set-Cookie 自动续期 __puus/__pus。
//

import Foundation

public final class UCProvider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .uc

    private static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "wmv", "rmvb"]

    private let http: HTTPClient
    private let lock = NSLock()
    private var guestPugs: String = ""
    public var onCookieRefreshed: (@Sendable (_ merged: String, _ requestCookie: String) -> Void)?

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func fetchNickname(credential: String) async -> String? {
        guard !credential.isEmpty else { return nil }
        let headers = [
            "Cookie": credential,
            "User-Agent": UCConstants.userAgent
        ]
        guard let resp = try? await http.send(url: UCConstants.accountInfoURL, headers: headers),
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

    public func refreshSession(cookie: String) async -> String {
        guard !cookie.isEmpty else { return cookie }
        let headers = [
            "Cookie": CookieHelper.withoutPuus(cookie),
            "User-Agent": UCConstants.userAgent,
            "Referer": UCConstants.downloadReferer
        ]
        guard let resp = try? await http.send(url: UCConstants.configURL, headers: headers) else {
            return cookie
        }
        let merged = CookieHelper.merge(original: cookie, setCookies: resp.setCookies)
        if merged != cookie {
            onCookieRefreshed?(merged, cookie)
        }
        return merged
    }

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let effectivePwd = (pwd?.isEmpty == false ? pwd : parsed.pwd) ?? ""
        let payload: [String: Any] = [
            "pwd_id": parsed.shareId,
            "passcode": effectivePwd,
            "share_for_transfer": true
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        var headers = [
            "User-Agent": UCConstants.userAgent,
            "Content-Type": "application/json"
        ]
        if !credential.isEmpty { headers["Cookie"] = credential }

        let resp = try await http.send(url: UCConstants.shareTokenURL, method: "POST", headers: headers, body: bodyData)
        let data = try unwrapEnvelope(resp: resp, originalCookie: credential)
        let stoken = data["stoken"] as? String ?? ""
        guard !stoken.isEmpty else {
            throw ProviderError.missingData("获取 UC 分享凭证失败，请检查链接或提取码")
        }
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ShareSession(
            platform: .uc,
            shareId: parsed.shareId,
            stoken: stoken,
            title: title.isEmpty ? "UC 分享" : title,
            originalLink: parsed.rawUrl,
            passcode: effectivePwd.isEmpty ? nil : effectivePwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        let encodedToken = session.stoken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.stoken
        let pdir = dirFid.isEmpty ? UCConstants.defaultPdirFid : dirFid

        for page in 1...100 {
            let url = "\(UCConstants.transferShareDetailURL)&pwd_id=\(session.shareId)&pdir_fid=\(pdir)&fetch_file_list=1&passcode=&_page=\(page)&_size=50&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort=&stoken=\(encodedToken)"
            var headers = [
                "User-Agent": UCConstants.userAgent,
                "Origin": "https://fast.uc.cn",
                "Referer": "https://fast.uc.cn/"
            ]
            if !credential.isEmpty { headers["Cookie"] = credential }

            let resp = try await http.send(url: url, method: "GET", headers: headers)
            let data = try unwrapEnvelope(resp: resp, originalCookie: credential)
            let list = (data["list"] as? [[String: Any]])
                ?? ((data["detail_info"] as? [String: Any])?["list"] as? [[String: Any]])
                ?? []

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
            if batch.count < 50 { break }
        }
        return all
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard !credential.isEmpty else {
            throw ProviderError.loginRequired(.uc)
        }
        let freshCookie = await refreshSession(cookie: credential)

        // 视频优先走 video_preview 取原画直链，绕过非会员宣传片替换
        if Self.isVideo(file.fname),
           let preview = await fetchVideoPreview(session: session, file: file, cookie: freshCookie) {
            return preview
        }

        let payload: [String: Any] = [
            "fids": [file.fid],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "fids_token": [file.fidToken]
        ]
        return try await requestDownloadLink(cookie: freshCookie, payload: payload, isGuest: false)
    }

    public func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        let payload: [String: Any] = [
            "fids": [file.fid],
            "pwd_id": session.shareId,
            "stoken": session.stoken,
            "fids_token": [file.fidToken]
        ]
        return try await requestDownloadLink(cookie: currentGuestPugs(), payload: payload, isGuest: true)
    }

    // MARK: - 内部请求

    private func fetchVideoPreview(session: ShareSession, file: ShareFile, cookie: String) async -> DownloadLink? {
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }
        let url = "\(UCConstants.videoPreviewURL)?pr=UCBrowser&fr=h5&pwd_id=\(enc(session.shareId))&stoken=\(enc(session.stoken))&fid=\(enc(file.fid))&fid_token=\(enc(file.fidToken))"
        let headers = [
            "Cookie": cookie,
            "User-Agent": UCConstants.userAgent,
            "Origin": UCConstants.webOrigin,
            "Referer": UCConstants.downloadReferer,
            "Content-Type": "application/json"
        ]
        guard let resp = try? await http.send(url: url, method: "GET", headers: headers),
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return nil
        }
        let status = (json["status"] as? NSNumber)?.intValue ?? 0
        let code = (json["code"] as? NSNumber)?.intValue ?? 0
        guard status == 200 || code == 0,
              let data = json["data"] as? [String: Any],
              let playInfo = data["play_info"] as? [String: Any],
              let directUrl = playInfo["url"] as? String, !directUrl.isEmpty else {
            return nil
        }
        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: directUrl,
            size: (playInfo["size"] as? NSNumber)?.int64Value ?? file.fsize
        )
    }

    private func requestDownloadLink(cookie: String, payload: [String: Any], isGuest: Bool) async throws -> DownloadLink {
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        var headers: [String: String] = ["Content-Type": "application/json"]
        if isGuest {
            headers["User-Agent"] = UCConstants.guestUA
            headers["Sec-Ch-Ua"] = UCConstants.guestSecChUA
        } else {
            headers["User-Agent"] = UCConstants.userAgent
        }
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        let resp = try await http.send(url: UCConstants.downloadURL, method: "POST", headers: headers, body: bodyData)
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
            let msg = (json["message"] as? String) ?? ""
            if isGuest {
                switch code {
                case 31001: throw ProviderError.apiMessage("该分享需要登录 UC 网盘后下载", code: code)
                case 23018: throw ProviderError.apiMessage("超出游客大小上限，请登录后下载", code: code)
                case 14001: throw ProviderError.apiMessage("UC 分享已失效或提取码错误", code: code)
                case 41020: throw ProviderError.apiMessage("分享令牌已过期，请重新解析", code: code)
                default: throw ProviderError.apiMessage(msg.isEmpty ? "获取 UC 游客直链失败" : msg, code: code)
                }
            }
            throw ProviderError.apiMessage(msg.isEmpty ? "获取 UC 下载直链失败" : msg, code: code)
        }

        guard let list = json["data"] as? [[String: Any]], let first = list.first else {
            throw ProviderError.missingData("UC 响应缺少直链数据")
        }
        let downloadUrl = first["download_url"] as? String ?? ""
        guard !downloadUrl.isEmpty else {
            throw ProviderError.missingData("未能提取到有效 UC 下载直链")
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
            let msg = (json["message"] as? String) ?? "UC 请求失败"
            let code = (json["code"] as? NSNumber)?.intValue
            throw ProviderError.apiMessage(msg, code: code)
        }
        guard let data = json["data"] as? [String: Any] else {
            throw ProviderError.missingData("UC 响应缺少 data 字段")
        }
        return data
    }

    private static func isVideo(_ fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
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
