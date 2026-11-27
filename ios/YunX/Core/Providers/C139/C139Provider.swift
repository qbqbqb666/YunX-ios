//
//  C139Provider.swift
//  YunX
//
//  139 云盘（和彩云）分享解析器：
//  - getOutLinkGeneral 匿名自动补全标题与明文提取码；
//  - getOutLinkInfoV6 匿名加密列目录（同时合并 caLst 子目录 + coLst 文件）；
//  - dlFromOutLinkV3 加密签名直出 OBS 高速下载直链（900s 有效）。
//

import Foundation

public final class C139Provider: ShareResolveProvider, Sendable {
    public let platform: SharePlatform = .c139
    private let http: HTTPClient

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func fetchNickname(credential: String) async -> String? {
        guard C139Constants.isValidCookie(credential) else { return nil }
        return C139Constants.extractDisplayAccount(credential) ?? "139 用户"
    }

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let linkId = parsed.shareId
        let general = await fetchOutLinkGeneral(linkId: linkId)
        let effectivePwd = (pwd?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? pwd!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (parsed.pwd ?? general.passwd ?? "")
        let title = general.title.isEmpty ? "139 云盘分享" : general.title
        return ShareSession(
            platform: .c139,
            shareId: linkId,
            stoken: effectivePwd,
            title: title,
            originalLink: parsed.rawUrl,
            passcode: effectivePwd.isEmpty ? nil : effectivePwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let pcaId = dirFid.isEmpty ? "root" : dirFid
        let reqBody: [String: Any] = [
            "getOutLinkInfoReq": [
                "account": "",
                "linkID": session.shareId,
                "passwd": session.stoken,
                "caSrt": 1,
                "coSrt": 1,
                "srtDr": 0,
                "bNum": 1,
                "pCaID": pcaId,
                "eNum": 200
            ]
        ]
        let plain = try compactJSONString(reqBody)
        let json = try await sharePostAnonymous(url: C139Constants.shareListURL, plainBody: plain)
        try checkResult(json, fallback: "获取 139 分享目录失败")

        guard let data = json["data"] as? [String: Any] else { return [] }
        var result: [ShareFile] = []

        // 1) 子文件夹列表 caLst
        if let caList = data["caLst"] as? [[String: Any]] {
            for item in caList {
                let id = stringValue(item["caID"])
                guard !id.isEmpty else { continue }
                let name = stringValue(item["caName"])
                let mtime = stringValue(item["udTime"]).isEmpty ? stringValue(item["ctTime"]) : stringValue(item["udTime"])
                result.append(ShareFile(
                    fid: id,
                    fname: name,
                    fsize: 0,
                    isdir: true,
                    pdirFid: pcaId,
                    fidToken: "",
                    modifyTime: mtime
                ))
            }
        }

        // 2) 文件列表 coLst（coType == 2 也可能是文件夹）
        if let coList = data["coLst"] as? [[String: Any]] {
            for item in coList {
                let id = stringValue(item["coID"])
                guard !id.isEmpty else { continue }
                let name = stringValue(item["coName"])
                let size = int64Value(item["coSize"])
                let isDir: Bool
                if let b = item["isdir"] as? Bool {
                    isDir = b
                } else {
                    isDir = intValue(item["coType"], default: 1) == 2
                }
                let mtime = stringValue(item["udTime"]).isEmpty ? stringValue(item["ctTime"]) : stringValue(item["udTime"])
                result.append(ShareFile(
                    fid: id,
                    fname: name,
                    fsize: isDir ? 0 : size,
                    isdir: isDir,
                    pdirFid: pcaId,
                    fidToken: "",
                    modifyTime: mtime
                ))
            }
        }
        return result
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        guard !credential.isEmpty else {
            throw ProviderError.loginRequired(.c139)
        }
        let authorization = C139Constants.extractAuthorization(credential)
        let account = C139Constants.extractAccountFull(credential)
            ?? authorization.flatMap(C139Constants.accountFromAuthorization)
            ?? ""
        guard !account.isEmpty else {
            throw ProviderError.apiMessage("139 登录凭证缺少账号信息，请重新登录 139 云盘")
        }

        let reqBody: [String: Any] = [
            "dlFromOutLinkReqV3": [
                "account": account,
                "linkID": session.shareId,
                "coIDLst": ["item": [file.fid]],
                "commonAccountInfo": [
                    "account": account,
                    "accountType": 1
                ]
            ]
        ]
        let plain = try compactJSONString(reqBody)
        let json = try await sharePostEncrypted(
            url: C139Constants.shareLinkURL,
            plainBody: plain,
            authorization: authorization
        )
        try checkResult(json, fallback: "获取 139 下载直链失败")

        guard let data = json["data"] as? [String: Any],
              let url = data["redrUrl"] as? String, !url.isEmpty else {
            throw ProviderError.missingData("139 未返回有效下载地址，请检查登录状态")
        }
        let fileName = [data["fileName"] as? String, data["coName"] as? String, file.fname]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? file.fname
        let size = int64Value(data["coSize"]) > 0 ? int64Value(data["coSize"]) : max(int64Value(data["size"]), file.fsize)
        return DownloadLink(
            fid: file.fid,
            filename: fileName,
            downloadUrl: url,
            size: size
        )
    }

    // MARK: - 内部请求封装

    private func fetchOutLinkGeneral(linkId: String) async -> (title: String, passwd: String?) {
        let reqBody: [String: Any] = [
            "getOutLinkGeneralReq": [
                "linkID": linkId,
                "isPasswd": 1,
                "account": ""
            ]
        ]
        guard let plain = try? compactJSONString(reqBody),
              let json = try? await sharePostAnonymous(url: C139Constants.shareGeneralURL, plainBody: plain),
              let data = json["data"] as? [String: Any],
              let resp = data["getOutLinkGeneralResp"] as? [String: Any],
              let list = resp["outLinkGeneral"] as? [[String: Any]],
              let first = list.first else {
            return ("", nil)
        }
        let title = (first["lkName"] as? String) ?? ""
        let pwd = (first["passwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (title, pwd)
    }

    private func sharePostAnonymous(url: String, plainBody: String) async throws -> [String: Any] {
        let encrypted = try C139Crypto.encryptBody(plainBody)
        let headers: [String: String] = [
            "hcy-cool-flag": "1",
            "x-deviceinfo": C139Constants.shareXDeviceInfo,
            "x-huawei-channelsrc": C139Constants.shareXHuaweiChannelSrc,
            "x-mm-source": C139Constants.shareXMMSource,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": C139Constants.shareMobileUA,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*"
        ]
        let resp = try await http.send(url: url, method: "POST", headers: headers, body: encrypted.data(using: .utf8))
        return try decodeResponseJSON(resp)
    }

    private func sharePostEncrypted(url: String, plainBody: String, authorization: String?) async throws -> [String: Any] {
        let encrypted = try C139Crypto.encryptBody(plainBody)
        var headers: [String: String] = [
            "hcy-cool-flag": "1",
            "x-deviceinfo": C139Constants.shareXDeviceInfo,
            "x-huawei-channelsrc": C139Constants.shareXHuaweiChannelSrc,
            "x-mm-source": C139Constants.shareXMMSource,
            "mcloud-sign": C139Crypto.signHeader(bodyJson: plainBody),
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": C139Constants.shareMobileUA,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*"
        ]
        if let authorization, !authorization.isEmpty {
            headers["Authorization"] = authorization
        }
        let resp = try await http.send(url: url, method: "POST", headers: headers, body: encrypted.data(using: .utf8))
        return try decodeResponseJSON(resp)
    }

    private func decodeResponseJSON(_ resp: HTTPResponseData) throws -> [String: Any] {
        let rawText = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            throw HTTPClientError.emptyBody(resp.statusCode)
        }
        if let decrypted = try? C139Crypto.decryptBody(rawText),
           let data = decrypted.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        if let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] {
            return obj
        }
        throw HTTPClientError.invalidJSON(resp.statusCode)
    }

    private func checkResult(_ json: [String: Any], fallback: String) throws {
        let code = stringValue(json["resultCode"])
        let success = (json["success"] as? Bool) ?? true
        if (code.isEmpty || code == "0") && success { return }
        let desc = (json["desc"] as? String) ?? (json["message"] as? String) ?? ""
        if code == "9188" {
            throw ProviderError.apiMessage("139 分享提取码错误或缺失（9188）")
        }
        throw ProviderError.apiMessage(desc.isEmpty ? "\(fallback)（错误码 \(code)）" : desc)
    }

    private func compactJSONString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
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
