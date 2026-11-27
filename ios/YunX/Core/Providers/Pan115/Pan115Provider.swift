//
//  Pan115Provider.swift
//  YunX
//
//  115 网盘解析器：
//  - 匿名/登录态分享列目录（share/snap）；
//  - 小文件直出分享直链（share/downurl），遇 50029 大文件拒绝时自动走「临时子目录转存 + 电脑端 RSA/XOR 加密接口」；
//  - 响应头路径绑定 900s CDN Cookie 随 DownloadLink.guestCookie 带出，与登录 Cookie 合并下载。
//

import Foundation

public final class Pan115Provider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .pan115
    internal let http: HTTPClient
    private let versionLock = NSLock()
    private var versionRefreshed = false

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - 账号校验

    public func fetchNickname(credential: String) async -> String? {
        guard Pan115Constants.hasLoginCookie(credential) else { return nil }
        do {
            let resp = try await http.send(
                url: Pan115Constants.userInfoURL,
                headers: apiHeaders(cookie: credential)
            )
            guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
                return nil
            }
            if intValue(json["errno"]) != 0 { return nil }
            if let dataStr = json["data"] as? String, !dataStr.isEmpty {
                return dataStr
            }
            if let dataObj = json["data"] as? [String: Any] {
                for key in ["user_name", "name", "nick_name"] {
                    if let s = dataObj[key] as? String, !s.isEmpty { return s }
                }
            }
            return Pan115Constants.extractUserId(credential)
        } catch {
            return nil
        }
    }

    // MARK: - 分享会话与列目录

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let receiveCode = (pwd ?? parsed.pwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let snap = try await fetchShareSnap(
            shareCode: parsed.shareId,
            receiveCode: receiveCode,
            cid: Pan115Constants.rootCid,
            cookie: credential,
            limit: 20,
            offset: 0
        )
        let stoken = Pan115Constants.encodeShareToken(receiveCode: receiveCode, userId: snap.userId)
        return ShareSession(
            platform: .pan115,
            shareId: parsed.shareId,
            stoken: stoken,
            title: snap.title.isEmpty ? "115 分享" : snap.title,
            originalLink: parsed.rawUrl,
            passcode: receiveCode.isEmpty ? nil : receiveCode
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let (receiveCode, _) = Pan115Constants.decodeShareToken(session.stoken)
        let cid = dirFid.isEmpty ? Pan115Constants.rootCid : dirFid
        var all: [ShareFile] = []
        var offset = 0
        for _ in 0..<20 {
            let snap = try await fetchShareSnap(
                shareCode: session.shareId,
                receiveCode: receiveCode,
                cid: cid,
                cookie: credential,
                limit: Pan115Constants.sharePageLimit,
                offset: offset
            )
            all.append(contentsOf: snap.files)
            if snap.files.count < Pan115Constants.sharePageLimit { break }
            offset += snap.files.count
            if snap.totalCount > 0 && all.count >= snap.totalCount { break }
        }
        return all
    }

    // MARK: - 取下载直链（分享直链优先，大文件自动转存 + 电脑端加密通道）

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard !credential.isEmpty, Pan115Constants.hasLoginCookie(credential) else {
            throw ProviderError.loginRequired(.pan115)
        }
        await refreshClientVersionIfNeeded()

        let (receiveCode, sharerUid) = Pan115Constants.decodeShareToken(session.stoken)
        let effectiveSharerUid: String
        if !sharerUid.isEmpty {
            effectiveSharerUid = sharerUid
        } else {
            let snap = try await fetchShareSnap(
                shareCode: session.shareId,
                receiveCode: receiveCode,
                cid: Pan115Constants.rootCid,
                cookie: credential,
                limit: 1,
                offset: 0
            )
            effectiveSharerUid = snap.userId
        }

        // 1) 先试分享直链（小文件免转存即可成功）
        if !effectiveSharerUid.isEmpty {
            do {
                if let direct = try await fetchShareDirectDownload(
                    shareCode: session.shareId,
                    receiveCode: receiveCode,
                    fileId: file.fid,
                    sharerUid: effectiveSharerUid,
                    cookie: credential,
                    fallbackFile: file
                ) {
                    return direct
                }
            } catch let err as Pan115ApiError where err.errno == Pan115Constants.errnoClientTooOld || err.errno == Pan115Constants.errnoWebSizeLimit {
                // 大文件被 50029 / 50028 拒绝，继续走电脑端临时转存通道
            } catch {
                // 若非大文件限制且无法转存，记录并尝试转存兜底
            }
        }

        // 2) 转存到「YunX临时转存/tr_<ts>」并用电脑端 RSA/XOR 接口拿大文件直链
        let tempRootCid = try await ensureTempRootDir(cookie: credential)
        let subdirName = "\(Pan115Constants.tempSubdirPrefix)\(Int64(Date().timeIntervalSince1970 * 1000))"
        let subCid = try await createFolder(parentCid: tempRootCid, name: subdirName, cookie: credential)

        do {
            try await receiveShare(
                shareCode: session.shareId,
                receiveCode: receiveCode,
                fileId: file.fid,
                targetCid: subCid,
                cookie: credential
            )

            // 轮询等待转存文件出现在子目录中拿到 pickcode
            var pickcode = ""
            var savedFile = file
            for _ in 0..<8 {
                let items = try await listPersonalFiles(cid: subCid, cookie: credential)
                if let matched = items.first(where: { !$0.isdir && ($0.fname == file.fname || items.count == 1) }) {
                    pickcode = matched.fidToken
                    savedFile = matched
                    if !pickcode.isEmpty { break }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !pickcode.isEmpty else {
                throw ProviderError.missingData("115 转存后未找到目标文件，请稍后重试")
            }

            let appLink = try await fetchAppDownloadLink(pickcode: pickcode, cookie: credential, fallbackFile: savedFile)
            return DownloadLink(
                fid: file.fid,
                filename: appLink.filename.isEmpty ? file.fname : appLink.filename,
                downloadUrl: appLink.downloadUrl,
                size: appLink.size > 0 ? appLink.size : file.fsize,
                cleanupDirFid: "\(tempRootCid)|\(subCid)",
                guestCookie: appLink.guestCookie
            )
        } catch {
            await cleanupTempDir(dirFid: "\(tempRootCid)|\(subCid)", credential: credential)
            throw error
        }
    }

    public func cleanupTempDir(dirFid: String, credential: String) async {
        guard !dirFid.isEmpty, !credential.isEmpty else { return }
        let parts = dirFid.split(separator: "|", maxSplits: 1).map(String.init)
        let pid = parts.count == 2 ? parts[0] : Pan115Constants.rootCid
        let fid = parts.count == 2 ? parts[1] : dirFid
        let body = "pid=\(urlEncode(pid))&fid%5B0%5D=\(urlEncode(fid))&ignore_warn=1"
        _ = try? await http.send(
            url: Pan115Constants.fileDeleteURL,
            method: "POST",
            headers: formHeaders(cookie: credential),
            body: body.data(using: .utf8)
        )
    }

    // MARK: - 内部 API 调用

    private struct ShareSnapResult {
        let title: String
        let userId: String
        let totalCount: Int
        let files: [ShareFile]
    }

    private func fetchShareSnap(
        shareCode: String,
        receiveCode: String,
        cid: String,
        cookie: String,
        limit: Int,
        offset: Int
    ) async throws -> ShareSnapResult {
        var url = "\(Pan115Constants.shareSnapURL)?share_code=\(urlEncode(shareCode))" +
            "&receive_code=\(urlEncode(receiveCode))&offset=\(offset)&limit=\(limit)&cid=\(urlEncode(cid))"
        if !cid.isEmpty && cid != "0" {
            url += "&asc=1&o=file_name"
        }
        var headers = apiHeaders(cookie: cookie)
        headers["Referer"] = Pan115Constants.shareReferer(shareCode: shareCode, receiveCode: receiveCode)
        let resp = try await http.send(url: url, headers: headers)
        let json = try parseJSON(resp)
        try checkState(json, fallback: "获取 115 分享列表失败")

        let data = json["data"] as? [String: Any] ?? [:]
        let shareInfo = data["shareinfo"] as? [String: Any] ?? [:]
        let userInfo = data["userinfo"] as? [String: Any] ?? [:]
        let title = (shareInfo["share_title"] as? String) ?? ""
        let userId = stringValue(userInfo["user_id"])
        let totalCount = intValue(data["count"])
        let list = data["list"] as? [[String: Any]] ?? []

        let files: [ShareFile] = list.compactMap { item in
            let fid = stringValue(item["fid"])
            let cidItem = stringValue(item["cid"])
            let isDir = fid.isEmpty
            let id = isDir ? cidItem : fid
            guard !id.isEmpty else { return nil }
            let name = (item["n"] as? String) ?? ""
            let size = int64Value(item["s"])
            let pc = stringValue(item["pc"])
            let mtime = stringValue(item["t"])
            return ShareFile(
                fid: id,
                fname: name,
                fsize: isDir ? 0 : size,
                isdir: isDir,
                pdirFid: cid,
                fidToken: pc,
                modifyTime: mtime
            )
        }
        return ShareSnapResult(title: title, userId: userId, totalCount: totalCount, files: files)
    }

    private func fetchShareDirectDownload(
        shareCode: String,
        receiveCode: String,
        fileId: String,
        sharerUid: String,
        cookie: String,
        fallbackFile: ShareFile
    ) async throws -> DownloadLink? {
        let body = "share_code=\(urlEncode(shareCode))&receive_code=\(urlEncode(receiveCode))" +
            "&file_id=\(urlEncode(fileId))&user_id=\(urlEncode(sharerUid))"
        var headers = formHeaders(cookie: cookie)
        headers["User-Agent"] = Pan115Constants.clientUA
        headers["Referer"] = Pan115Constants.shareReferer(shareCode: shareCode, receiveCode: receiveCode)

        let resp = try await http.send(
            url: Pan115Constants.shareDownloadURL,
            method: "POST",
            headers: headers,
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "获取 115 分享直链失败")

        let data = json["data"] as? [String: Any] ?? [:]
        let urlObj = data["url"] as? [String: Any]
        let downloadUrl = (urlObj?["url"] as? String) ?? (data["url"] as? String) ?? ""
        guard !downloadUrl.isEmpty else { return nil }
        let fileName = (data["file_name"] as? String) ?? fallbackFile.fname
        let size = int64Value(data["file_size"])
        let cdnCookie = resp.extractPathBoundCookie()
        return DownloadLink(
            fid: fallbackFile.fid,
            filename: fileName.isEmpty ? fallbackFile.fname : fileName,
            downloadUrl: downloadUrl,
            size: size > 0 ? size : fallbackFile.fsize,
            guestCookie: cdnCookie
        )
    }

    internal func fetchAppDownloadLink(pickcode: String, cookie: String, fallbackFile: ShareFile) async throws -> DownloadLink {
        let key = Pan115Crypto.newKey()
        let payload = "{\"pickcode\":\"\(pickcode)\"}"
        let encoded = try Pan115Crypto.encode(payload: payload, key: key)
        let ts = Int64(Date().timeIntervalSince1970)
        let url = "\(Pan115Constants.appDownloadURL)?t=\(ts)"
        let formBody = "data=\(urlEncode(encoded))"

        var headers = formHeaders(cookie: cookie)
        headers["User-Agent"] = Pan115Constants.clientUA

        let resp = try await http.send(
            url: url,
            method: "POST",
            headers: headers,
            body: formBody.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "115 电脑端通道取直链失败")

        guard let encryptedData = json["data"] as? String, !encryptedData.isEmpty else {
            throw ProviderError.missingData("115 电脑端接口未返回加密数据")
        }
        let plainJsonText = try Pan115Crypto.decode(data: encryptedData, key: key)
        guard let plainData = plainJsonText.data(using: .utf8),
              let decoded = try JSONSerialization.jsonObject(with: plainData) as? [String: Any] else {
            throw ProviderError.missingData("115 电脑端接口解密结果解析失败")
        }

        // 解密后格式：{ "<fileId>": { "file_name": "...", "file_size": 123, "url": { "url": "https://..." } } }
        var foundUrl = ""
        var foundName = fallbackFile.fname
        var foundSize = fallbackFile.fsize
        for (_, val) in decoded {
            guard let entry = val as? [String: Any] else { continue }
            let urlVal: String
            if let urlObj = entry["url"] as? [String: Any], let u = urlObj["url"] as? String {
                urlVal = u
            } else if let u = entry["url"] as? String {
                urlVal = u
            } else {
                urlVal = ""
            }
            if !urlVal.isEmpty {
                foundUrl = urlVal
                if let fn = entry["file_name"] as? String, !fn.isEmpty { foundName = fn }
                let sz = int64Value(entry["file_size"])
                if sz > 0 { foundSize = sz }
                break
            }
        }
        guard !foundUrl.isEmpty else {
            throw ProviderError.missingData("115 电脑端接口未返回有效下载地址")
        }

        let cdnCookie = resp.extractPathBoundCookie()
        return DownloadLink(
            fid: fallbackFile.fid,
            filename: foundName,
            downloadUrl: foundUrl,
            size: foundSize,
            guestCookie: cdnCookie
        )
    }

    private func ensureTempRootDir(cookie: String) async throws -> String {
        let rootItems = try await listPersonalFiles(cid: Pan115Constants.rootCid, cookie: cookie)
        if let existing = rootItems.first(where: { $0.isdir && $0.fname == Pan115Constants.tempDirName }) {
            return existing.fid
        }
        return try await createFolder(parentCid: Pan115Constants.rootCid, name: Pan115Constants.tempDirName, cookie: cookie)
    }

    internal func createFolder(parentCid: String, name: String, cookie: String) async throws -> String {
        let body = "pid=\(urlEncode(parentCid))&cname=\(urlEncode(name))"
        let resp = try await http.send(
            url: Pan115Constants.fileAddURL,
            method: "POST",
            headers: formHeaders(cookie: cookie),
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "创建 115 临时目录失败")
        let cid = stringValue(json["cid"]).isEmpty ? stringValue(json["file_id"]) : stringValue(json["cid"])
        guard !cid.isEmpty else {
            throw ProviderError.missingData("创建 115 临时目录未返回目录 ID")
        }
        return cid
    }

    internal func receiveShare(shareCode: String, receiveCode: String, fileId: String, targetCid: String, cookie: String) async throws {
        let body = "share_code=\(urlEncode(shareCode))&receive_code=\(urlEncode(receiveCode))" +
            "&file_id=\(urlEncode(fileId))&cid=\(urlEncode(targetCid))"
        var headers = formHeaders(cookie: cookie)
        headers["Referer"] = Pan115Constants.shareReferer(shareCode: shareCode, receiveCode: receiveCode)
        let resp = try await http.send(
            url: Pan115Constants.shareReceiveURL,
            method: "POST",
            headers: headers,
            body: body.data(using: .utf8)
        )
        let json = try parseJSON(resp)
        try checkState(json, fallback: "115 转存分享文件失败")
    }

    internal func listPersonalFiles(cid: String, cookie: String) async throws -> [ShareFile] {
        let url = "\(Pan115Constants.filesURL)?aid=\(Pan115Constants.aidPersonal)&cid=\(urlEncode(cid))" +
            "&o=user_ptime&asc=0&offset=0&show_dir=1&limit=\(Pan115Constants.pageLimit)&format=json"
        let resp = try await http.send(url: url, headers: apiHeaders(cookie: cookie))
        let json = try parseJSON(resp)
        try checkState(json, fallback: "获取 115 目录失败")
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            let fid = stringValue(item["fid"])
            let cidItem = stringValue(item["cid"])
            let isDir = fid.isEmpty
            let id = isDir ? cidItem : fid
            guard !id.isEmpty else { return nil }
            return ShareFile(
                fid: id,
                fname: (item["n"] as? String) ?? "",
                fsize: isDir ? 0 : int64Value(item["s"]),
                isdir: isDir,
                pdirFid: cid,
                fidToken: stringValue(item["pc"]),
                modifyTime: stringValue(item["t"])
            )
        }
    }

    internal func refreshClientVersionIfNeeded() async {
        let shouldFetch: Bool = {
            versionLock.lock()
            defer { versionLock.unlock() }
            if versionRefreshed { return false }
            versionRefreshed = true
            return true
        }()
        guard shouldFetch else { return }
        if let resp = try? await http.send(url: Pan115Constants.appVersionURL, headers: ["User-Agent": Pan115Constants.webUA]),
           let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
           let data = json["data"] as? [String: Any],
           let win = data["win"] as? [String: Any],
           let ver = win["version_code"] as? String {
            Pan115Constants.applyClientVersion(ver)
        }
    }

    // MARK: - 辅助工具

    private struct Pan115ApiError: LocalizedError {
        let errno: Int
        let message: String
        var errorDescription: String? { message }
    }

    internal func apiHeaders(cookie: String) -> [String: String] {
        var h: [String: String] = [
            "User-Agent": Pan115Constants.webUA,
            "Referer": Pan115Constants.referer,
            "Accept": "application/json, text/plain, */*"
        ]
        if !cookie.isEmpty {
            h["Cookie"] = cookie
            h["X-Requested-With"] = Pan115Constants.xRequestedWith
        }
        return h
    }

    internal func formHeaders(cookie: String) -> [String: String] {
        var h = apiHeaders(cookie: cookie)
        h["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        return h
    }

    internal func parseJSON(_ resp: HTTPResponseData) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw HTTPClientError.invalidJSON(resp.statusCode)
        }
        return obj
    }

    internal func checkState(_ json: [String: Any], fallback: String) throws {
        let state = (json["state"] as? Bool) ?? (intValue(json["state"]) == 1)
        let errno = intValue(json["errno"])
        if state && errno == 0 { return }
        let serverMsg = (json["error"] as? String) ?? (json["msg"] as? String) ?? ""
        let mapped: String
        switch errno {
        case Pan115Constants.errnoLoginTimeout:
            mapped = "115 登录已过期，请在「账号」页重新登录"
        case Pan115Constants.errnoNeedCode:
            mapped = "该 115 分享需要访问码，请填写访问码后重试"
        case Pan115Constants.errnoWrongCode:
            mapped = "115 分享访问码错误"
        case Pan115Constants.errnoShareGone:
            mapped = "该 115 分享不存在或已被取消"
        default:
            mapped = serverMsg.isEmpty ? "\(fallback)（错误码 \(errno)）" : serverMsg
        }
        throw Pan115ApiError(errno: errno, message: mapped)
    }

    internal func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    internal func stringValue(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    internal func intValue(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s) { return i }
        return 0
    }

    internal func int64Value(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String, let i = Int64(s) { return i }
        return 0
    }
}
