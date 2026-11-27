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
        let path = file.fidToken.isEmpty ? file.fid : file.fidToken
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

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        guard let bdstoken = await getBdstoken(cookie: credential) else {
            throw ProviderError.apiMessage("获取百度 bdstoken 失败")
        }
        let paths = files.map { $0.fidToken.isEmpty ? $0.fid : $0.fidToken }.filter { !$0.isEmpty }
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

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard BaiduConstants.isValidCookie(credential) else {
            throw ProviderError.loginRequired(.baidu)
        }
        let path = file.fidToken.isEmpty ? file.fid : file.fidToken
        let directUrl = try await locateDownload(path: path, cookie: credential)
        return DownloadLink(fid: file.fid, filename: file.fname, downloadUrl: directUrl, size: file.fsize)
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
                // 目录用 path 作 fid 便于统一导航；文件用 fs_id 作 fid，path 放 fidToken 供 rename/delete/locateDownload 使用
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
                    fidToken: path,
                    modifyTime: stringValue(item["server_mtime"]),
                    thumbnail: thumb
                ))
            }
            if arr.count < pageSize || fresh == 0 { break }
        }
        return all
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
