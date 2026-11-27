//
//  GitHubProvider.swift
//  YunX
//
//  GitHub 仓库 / Release / 直链解析器：
//  - 支持仓库源码目录树、Releases 资产列表、账号仓库列表与文件直链解析；
//  - 支持可选 Personal Access Token 提升 API 速率上限（60 -> 5000 次/小时）。
//

import Foundation

public final class GitHubProvider: ShareResolveProvider, Sendable {
    public let platform: SharePlatform = .github
    private let http: HTTPClient

    public static let apiBase = "https://api.github.com"
    public static let defaultMirrorPrefix = "https://cdn.gh-proxy.org/"
    public static let userAgent = "YunX-iOS"

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    public func fetchNickname(credential: String) async -> String? {
        let token = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        guard let resp = try? await http.send(
            url: "\(Self.apiBase)/user",
            headers: apiHeaders(token: token)
        ), resp.isSuccessful,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return nil
        }
        let login = (json["login"] as? String) ?? ""
        return login.isEmpty ? nil : "@\(login)"
    }

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        guard let linkType = GitHubLinkParser.parse(parsed.rawUrl) else {
            throw ProviderError.unrecognizedLink
        }
        switch linkType {
        case .directFile(let url, let fileName):
            return ShareSession(
                platform: .github,
                shareId: "direct:\(fileName)",
                stoken: "direct|\(url)",
                title: fileName,
                originalLink: parsed.rawUrl
            )
        case .account(let owner):
            return ShareSession(
                platform: .github,
                shareId: "account:\(owner)",
                stoken: "account|\(owner)",
                title: "@\(owner)",
                originalLink: parsed.rawUrl
            )
        case .repository(let owner, let repo, let subPath):
            let branch = await fetchDefaultBranch(owner: owner, repo: repo, token: credential) ?? "main"
            return ShareSession(
                platform: .github,
                shareId: "\(owner)/\(repo)",
                stoken: "repo|\(owner)|\(repo)|\(branch)|\(subPath ?? "")",
                title: "\(owner)/\(repo)",
                originalLink: parsed.rawUrl
            )
        }
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        let parts = session.stoken.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let kind = parts.first ?? ""

        if kind == "direct" {
            let url = parts.dropFirst().joined(separator: "|")
            let name = session.title.isEmpty ? "file" : session.title
            return [
                ShareFile(fid: url, fname: name, fsize: 0, isdir: false, pdirFid: "", fidToken: url)
            ]
        }

        if kind == "account" {
            let owner = parts.count > 1 ? parts[1] : ""
            if dirFid.isEmpty {
                return try await listAccountRepos(owner: owner, token: credential)
            }
            // 进入具体仓库：dirFid 形如 repo:<owner>/<repo>:<branch>:<path>
            return try await listRepoNode(nodeId: dirFid, token: credential)
        }

        if kind == "repo" {
            let owner = parts.count > 1 ? parts[1] : ""
            let repo = parts.count > 2 ? parts[2] : ""
            let branch = parts.count > 3 ? parts[3] : "main"
            let subPath = parts.count > 4 ? parts[4] : ""

            if dirFid.isEmpty {
                // 若分享链接直接指向 releases，则直接列出 Releases
                if subPath.lowercased().hasPrefix("releases") {
                    return try await listReleases(owner: owner, repo: repo, token: credential)
                }
                var initialPath = ""
                var initialBranch = branch
                if subPath.hasPrefix("tree/") || subPath.hasPrefix("blob/") {
                    let segs = subPath.split(separator: "/").map(String.init)
                    if segs.count >= 2 {
                        initialBranch = segs[1]
                        initialPath = segs.dropFirst(2).joined(separator: "/")
                    }
                }
                var items: [ShareFile] = []
                if initialPath.isEmpty {
                    // 根目录顶部提供 Releases 虚拟入口 + 源码压缩包
                    items.append(ShareFile(
                        fid: "releases:\(owner)/\(repo)",
                        fname: "📦 Releases 发布版本",
                        fsize: 0,
                        isdir: true,
                        pdirFid: "",
                        fidToken: ""
                    ))
                    items.append(ShareFile(
                        fid: "https://github.com/\(owner)/\(repo)/archive/refs/heads/\(initialBranch).zip",
                        fname: "\(repo)-\(initialBranch).zip",
                        fsize: 0,
                        isdir: false,
                        pdirFid: "",
                        fidToken: "https://github.com/\(owner)/\(repo)/archive/refs/heads/\(initialBranch).zip"
                    ))
                }
                let contents = try await listContents(owner: owner, repo: repo, path: initialPath, ref: initialBranch, token: credential)
                items.append(contentsOf: contents)
                return items
            }
            return try await listRepoNode(nodeId: dirFid, token: credential)
        }
        return []
    }

    public func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        try await getShareDownloadLink(session: session, file: file, credential: "", preferNoSave: true)
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        let directUrl = file.fidToken.isEmpty ? file.fid : file.fidToken
        guard directUrl.hasPrefix("http://") || directUrl.hasPrefix("https://") else {
            throw ProviderError.missingData("未找到有效的 GitHub 文件直链")
        }
        return DownloadLink(
            fid: file.fid,
            filename: file.fname,
            downloadUrl: directUrl,
            size: file.fsize
        )
    }

    // MARK: - GitHub REST API

    private func listRepoNode(nodeId: String, token: String) async throws -> [ShareFile] {
        if nodeId.hasPrefix("releases:") {
            let repoSlug = String(nodeId.dropFirst("releases:".count))
            let segs = repoSlug.split(separator: "/").map(String.init)
            guard segs.count == 2 else { return [] }
            return try await listReleases(owner: segs[0], repo: segs[1], token: token)
        }
        if nodeId.hasPrefix("release_tag:") {
            // release_tag:<owner>/<repo>|<tag>
            let rest = String(nodeId.dropFirst("release_tag:".count))
            let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return [] }
            let segs = parts[0].split(separator: "/").map(String.init)
            guard segs.count == 2 else { return [] }
            return try await listReleaseAssets(owner: segs[0], repo: segs[1], tag: parts[1], token: token)
        }
        if nodeId.hasPrefix("tree:") {
            // tree:<owner>/<repo>|<ref>|<path>
            let rest = String(nodeId.dropFirst("tree:".count))
            let parts = rest.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return [] }
            let segs = parts[0].split(separator: "/").map(String.init)
            guard segs.count == 2 else { return [] }
            return try await listContents(owner: segs[0], repo: segs[1], path: parts[2], ref: parts[1], token: token)
        }
        if nodeId.hasPrefix("repo:") {
            // repo:<owner>/<repo>|<branch>
            let rest = String(nodeId.dropFirst("repo:".count))
            let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return [] }
            let segs = parts[0].split(separator: "/").map(String.init)
            guard segs.count == 2 else { return [] }
            var items: [ShareFile] = [
                ShareFile(fid: "releases:\(segs[0])/\(segs[1])", fname: "📦 Releases 发布版本", fsize: 0, isdir: true, pdirFid: nodeId)
            ]
            items.append(contentsOf: try await listContents(owner: segs[0], repo: segs[1], path: "", ref: parts[1], token: token))
            return items
        }
        return []
    }

    private func fetchDefaultBranch(owner: String, repo: String, token: String) async -> String? {
        guard let resp = try? await http.send(
            url: "\(Self.apiBase)/repos/\(owner)/\(repo)",
            headers: apiHeaders(token: token)
        ), resp.isSuccessful,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            return nil
        }
        return json["default_branch"] as? String
    }

    private func listAccountRepos(owner: String, token: String) async throws -> [ShareFile] {
        let resp = try await http.send(
            url: "\(Self.apiBase)/users/\(owner)/repos?sort=updated&per_page=100",
            headers: apiHeaders(token: token)
        )
        try checkResponse(resp, fallback: "获取 GitHub 仓库列表失败")
        let arr = (try? JSONSerialization.jsonObject(with: resp.body) as? [[String: Any]]) ?? []
        return arr.compactMap { item in
            let name = (item["name"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let branch = (item["default_branch"] as? String) ?? "main"
            return ShareFile(
                fid: "repo:\(owner)/\(name)|\(branch)",
                fname: name,
                fsize: 0,
                isdir: true,
                pdirFid: "",
                fidToken: "",
                modifyTime: (item["updated_at"] as? String) ?? ""
            )
        }
    }

    private func listContents(owner: String, repo: String, path: String, ref: String, token: String) async throws -> [ShareFile] {
        let encodedPath = path.split(separator: "/").map { urlEncode(String($0)) }.joined(separator: "/")
        let pathPart = encodedPath.isEmpty ? "" : "/\(encodedPath)"
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/contents\(pathPart)?ref=\(urlEncode(ref))"
        let resp = try await http.send(url: url, headers: apiHeaders(token: token))
        try checkResponse(resp, fallback: "获取 GitHub 目录内容失败")

        let rawObj = try? JSONSerialization.jsonObject(with: resp.body)
        let list: [[String: Any]]
        if let arr = rawObj as? [[String: Any]] {
            list = arr
        } else if let single = rawObj as? [String: Any] {
            list = [single]
        } else {
            list = []
        }

        return list.compactMap { item in
            let name = (item["name"] as? String) ?? ""
            let itemPath = (item["path"] as? String) ?? name
            let type = (item["type"] as? String) ?? "file"
            let isDir = type == "dir"
            let dlUrl = (item["download_url"] as? String)
                ?? "https://raw.githubusercontent.com/\(owner)/\(repo)/\(ref)/\(itemPath)"
            let fid = isDir ? "tree:\(owner)/\(repo)|\(ref)|\(itemPath)" : dlUrl
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            return ShareFile(
                fid: fid,
                fname: name,
                fsize: isDir ? 0 : size,
                isdir: isDir,
                pdirFid: path,
                fidToken: isDir ? "" : dlUrl
            )
        }
    }

    private func listReleases(owner: String, repo: String, token: String) async throws -> [ShareFile] {
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/releases?per_page=30"
        let resp = try await http.send(url: url, headers: apiHeaders(token: token))
        try checkResponse(resp, fallback: "获取 GitHub Releases 失败")
        let arr = (try? JSONSerialization.jsonObject(with: resp.body) as? [[String: Any]]) ?? []
        return arr.compactMap { rel in
            let tag = (rel["tag_name"] as? String) ?? ""
            guard !tag.isEmpty else { return nil }
            let name = (rel["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag
            return ShareFile(
                fid: "release_tag:\(owner)/\(repo)|\(tag)",
                fname: name,
                fsize: 0,
                isdir: true,
                pdirFid: "releases:\(owner)/\(repo)",
                modifyTime: (rel["published_at"] as? String) ?? ""
            )
        }
    }

    private func listReleaseAssets(owner: String, repo: String, tag: String, token: String) async throws -> [ShareFile] {
        let url = "\(Self.apiBase)/repos/\(owner)/\(repo)/releases/tags/\(urlEncode(tag))"
        let resp = try await http.send(url: url, headers: apiHeaders(token: token))
        try checkResponse(resp, fallback: "获取 Release 附件失败")
        guard let rel = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else { return [] }

        var items: [ShareFile] = []
        if let assets = rel["assets"] as? [[String: Any]] {
            for a in assets {
                let name = (a["name"] as? String) ?? ""
                let dlUrl = (a["browser_download_url"] as? String) ?? ""
                guard !name.isEmpty, !dlUrl.isEmpty else { continue }
                let size = (a["size"] as? NSNumber)?.int64Value ?? 0
                items.append(ShareFile(
                    fid: dlUrl,
                    fname: name,
                    fsize: size,
                    isdir: false,
                    pdirFid: tag,
                    fidToken: dlUrl,
                    modifyTime: (a["updated_at"] as? String) ?? ""
                ))
            }
        }
        if let zipUrl = rel["zipball_url"] as? String, !zipUrl.isEmpty {
            items.append(ShareFile(
                fid: zipUrl,
                fname: "Source code (\(tag)).zip",
                fsize: 0,
                isdir: false,
                pdirFid: tag,
                fidToken: zipUrl
            ))
        }
        return items
    }

    private func apiHeaders(token: String) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": Self.userAgent
        ]
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            h["Authorization"] = "Bearer \(trimmed)"
        }
        return h
    }

    private func checkResponse(_ resp: HTTPResponseData, fallback: String) throws {
        if resp.isSuccessful { return }
        if resp.statusCode == 403 && resp.header("X-RateLimit-Remaining") == "0" {
            throw ProviderError.apiMessage("GitHub API 匿名调用已达每小时 60 次上限，请在「账号」页配置 GitHub Token 后重试")
        }
        if resp.statusCode == 404 {
            throw ProviderError.apiMessage("GitHub 仓库或路径不存在（404）")
        }
        throw HTTPClientError.httpError(resp.statusCode, fallback)
    }

    private func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
