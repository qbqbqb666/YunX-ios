//
//  QuarkProvider+CloudDrive.swift
//  YunX
//
//  夸克网盘个人空间管理与分享转存实现（独立分区文件）。
//

import Foundation

extension QuarkProvider: CloudDriveProvider {
    public func fetchQuota(credential: String) async -> CloudQuota? {
        guard !credential.isEmpty else { return nil }
        let headers = [
            "Cookie": credential,
            "User-Agent": QuarkConstants.apiUserAgent
        ]
        guard let data = try? await getJSONData(url: QuarkConstants.memberURL, headers: headers, originalCookie: credential) else {
            return nil
        }
        let used = (data["use_capacity"] as? NSNumber)?.int64Value ?? 0
        let total = (data["total_capacity"] as? NSNumber)?.int64Value ?? 0
        return total > 0 ? CloudQuota(used: used, total: total) : nil
    }

    public func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile] {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let pdir = dirFid.isEmpty ? QuarkConstants.defaultPdirFid : dirFid
        let thumbHeaders = [
            "User-Agent": QuarkConstants.apiUserAgent,
            "Referer": QuarkConstants.downloadReferer
        ]
        let thumbAuthHeaders = [
            "Cookie": freshCookie,
            "User-Agent": QuarkConstants.apiUserAgent,
            "Referer": QuarkConstants.downloadReferer
        ]

        var all: [ShareFile] = []
        for page in 1...100 {
            let url = "\(QuarkConstants.cloudFileSortURL)&uc_param_str=&pdir_fid=\(pdir)&_page=\(page)&_size=100&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc&fetch_all_file=1&fetch_risk_file_name=1"
            let headers = [
                "Cookie": freshCookie,
                "User-Agent": QuarkConstants.apiUserAgent,
                "Origin": "https://pan.quark.cn",
                "Referer": QuarkConstants.downloadReferer
            ]
            let data = try await getJSONData(url: url, headers: headers, originalCookie: freshCookie)
            let list = data["list"] as? [[String: Any]] ?? []
            let batch = list.map { item in
                let rawName = (item["file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (item["fname"] as? String) ?? ""
                let thumb = FileThumbnail.hostScoped(
                    url: item["thumbnail"] as? String ?? "",
                    headers: thumbHeaders,
                    authHost: QuarkConstants.thumbnailHost,
                    authHeaders: thumbAuthHeaders
                )
                return ShareFile(
                    fid: item["fid"] as? String ?? "",
                    fname: rawName,
                    fsize: (item["size"] as? NSNumber)?.int64Value ?? 0,
                    isdir: (item["dir"] as? Bool) ?? false,
                    pdirFid: item["pdir_fid"] as? String ?? pdir,
                    fidToken: "",
                    modifyTime: Self.stringValue(item["updated_at"]),
                    thumbnail: thumb
                )
            }
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return all
    }

    public func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let pdir = parentFid.isEmpty ? QuarkConstants.defaultPdirFid : parentFid
        return try await createFolder(name: name, parentFid: pdir, cookie: credential)
    }

    public func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let body: [String: Any] = [
            "fid": file.fid,
            "file_name": newName
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let resp = try await http.send(
            url: QuarkConstants.renameURL,
            method: "POST",
            headers: [
                "Cookie": credential,
                "User-Agent": QuarkConstants.apiUserAgent,
                "Content-Type": "application/json"
            ],
            body: bodyData
        )
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              (json["status"] as? NSNumber)?.intValue == 200 else {
            throw ProviderError.apiMessage("夸克重命名失败")
        }
    }

    public func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let ids = files.map(\.fid).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let payload: [String: Any] = [
            "action_type": 2,
            "filelist": ids,
            "exclude_fids": []
        ]
        _ = try await postJSONData(url: QuarkConstants.deleteURL, cookie: credential, body: payload)
    }

    public func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let link = try await requestDownloadLink(cookie: freshCookie, payload: ["fids": [file.fid]], isGuest: false)
        return link.filename.isEmpty ? link.withFilename(file.fname) : link
    }

    public func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws {
        guard !credential.isEmpty else { throw ProviderError.loginRequired(.quark) }
        let freshCookie = await refreshSession(cookie: credential)
        let targetDir = toDirFid.isEmpty ? QuarkConstants.defaultPdirFid : toDirFid
        let taskId = try await saveShareFile(session: session, file: file, toDirFid: targetDir, cookie: freshCookie)
        _ = try await pollTransferTask(taskId: taskId, cookie: freshCookie)
    }
}
