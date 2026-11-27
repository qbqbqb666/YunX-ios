//
//  LanzouProvider.swift
//  YunX
//
//  蓝奏云匿名分享完整解析实现：
//  - 单文件 / 文件夹分享页面解析（兼容新版 data 对象与旧版 JS 变量）；
//  - 文件夹分页 filemoreajax（含 zt=4 退避重试）；
//  - 加密提取码解析、同源 iframe 落地、ajaxm/ajaxfile 请求、HEAD/Range 探测与「验证并下载」处理；
//  - 自动应对 acw_sc__v2 校验页。
//

import Foundation

public struct LanzouFolderParams: Sendable {
    public let lx: String
    public let fid: String
    public let t: String
    public let k: String
}

public struct LanzouSharePage: Sendable {
    public let shareUrl: String
    public let baseUrl: String
    public let title: String
    public let isFolder: Bool
    public let needsPwd: Bool
    public let fileId: String?
    public let folderParams: LanzouFolderParams?
    public let html: String
    public let singleFile: ShareFile?
}

public final class LanzouProvider: ShareResolveProvider, @unchecked Sendable {
    public let platform: SharePlatform = .lanzou

    private let http: HTTPClient
    private let lock = NSLock()
    private var hostCookies: [String: [String: String]] = [:]
    private var pageCache: [String: LanzouSharePage] = [:]

    public init(http: HTTPClient = .shared) {
        self.http = http
    }

    // MARK: - ShareResolveProvider

    public func createSession(parsed: ParsedShare, pwd: String?, credential: String) async throws -> ShareSession {
        let effectivePwd = (pwd?.isEmpty == false ? pwd : parsed.pwd) ?? ""
        let page = try await resolveSharePage(urlString: parsed.rawUrl)
        if page.needsPwd && effectivePwd.isEmpty {
            throw ProviderError.apiMessage("该蓝奏云分享需要提取码，请填写后重新解析")
        }
        cachePage(page)
        return ShareSession(
            platform: .lanzou,
            shareId: page.shareUrl,
            stoken: effectivePwd,
            title: page.title,
            originalLink: page.shareUrl,
            passcode: effectivePwd.isEmpty ? nil : effectivePwd
        )
    }

    public func listFiles(session: ShareSession, dirFid: String, credential: String) async throws -> [ShareFile] {
        guard let page = cachedPage(for: session.shareId) else {
            throw ProviderError.missingData("蓝奏云分享会话已过期，请重新解析")
        }
        if page.isFolder {
            return try await listShareFolder(page: page, pwd: session.stoken)
        } else if let single = page.singleFile {
            return [single]
        }
        return []
    }

    public func getShareDownloadLink(
        session: ShareSession,
        file: ShareFile,
        credential: String,
        preferNoSave: Bool
    ) async throws -> DownloadLink {
        try await getGuestShareDownloadLink(session: session, file: file)
    }

    public func getGuestShareDownloadLink(session: ShareSession, file: ShareFile) async throws -> DownloadLink {
        guard let page = cachedPage(for: session.shareId) else {
            throw ProviderError.missingData("蓝奏云分享会话已过期，请重新解析")
        }
        let pwd = session.stoken.isEmpty ? nil : session.stoken
        return try await resolveDirectLink(page: page, file: file, pwd: pwd)
    }

    // MARK: - 分享页与文件夹解析

    private func resolveSharePage(urlString: String) async throws -> LanzouSharePage {
        let normalized = LanzouConstants.normalizeShareURL(urlString)
        let html = try await fetchPageFollowingLanzou(normalized)
        guard let uri = URL(string: normalized), let scheme = uri.scheme, let host = uri.host else {
            throw ProviderError.unrecognizedLink
        }
        let origin = "\(scheme)://\(host)"
        let title = extractTitle(from: html)
        let needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"")
            || html.contains("input_password") || html.contains("密码不正确")
            || html.contains("function down_p(")
        let isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"")
            || html.contains("file_more")
        let fileId = firstCapture(pattern: #"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? firstCapture(pattern: #"name=["']file["']\s+value=["'](\d+)["']"#, in: html)
            ?? firstCapture(pattern: #"file=(\d+)"#, in: html)

        var folderParams: LanzouFolderParams?
        if isFolder {
            let lx = jsVar(in: html, name: "lx")
            let fid = jsVar(in: html, name: "fid") ?? uri.lastPathComponent
            let t = jsVar(in: html, name: "t")
            let k = jsVar(in: html, name: "k")
            if let lx, let t, let k {
                folderParams = LanzouFolderParams(lx: lx, fid: fid, t: t, k: k)
            }
        }

        let shareId = uri.lastPathComponent
        let displaySize: Int64
        if let captures = allCaptures(pattern: #"(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?"#, in: html),
           captures.count >= 2 {
            displaySize = parseDisplaySize("\(captures[0]) \(captures[1])")
        } else {
            displaySize = 0
        }

        let singleFile: ShareFile? = isFolder ? nil : ShareFile(
            fid: shareId,
            fname: title.isEmpty ? "蓝奏文件" : title,
            fsize: displaySize,
            isdir: false
        )

        return LanzouSharePage(
            shareUrl: normalized,
            baseUrl: origin,
            title: title.isEmpty ? "蓝奏分享" : title,
            isFolder: isFolder,
            needsPwd: needsPwd,
            fileId: fileId,
            folderParams: folderParams,
            html: html,
            singleFile: singleFile
        )
    }

    private func listShareFolder(page: LanzouSharePage, pwd: String) async throws -> [ShareFile] {
        guard let params = page.folderParams else {
            throw ProviderError.missingData("蓝奏云文件夹分页参数缺失")
        }
        var all: [ShareFile] = []
        var seen: Set<String> = []
        var pg = 1
        var retries = 0

        while pg <= 100 {
            if pg > 1 || retries > 0 {
                let waitMs = retries > 0 ? 600 * (retries + 1) : 250
                try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            }
            let json: [String: Any]
            do {
                json = try await formPostJSON(
                    url: "\(page.baseUrl)/filemoreajax.php",
                    fields: [
                        ("lx", params.lx),
                        ("fid", params.fid),
                        ("t", params.t),
                        ("k", params.k),
                        ("pwd", pwd),
                        ("pg", String(pg))
                    ],
                    referer: page.shareUrl,
                    origin: page.baseUrl
                )
            } catch {
                retries += 1
                if retries > 2 { throw ProviderError.apiMessage("蓝奏云请求过于频繁，请稍后再试") }
                continue
            }

            let zt = (json["zt"] as? NSNumber)?.intValue ?? 0
            if zt == 4 {
                retries += 1
                if retries > 2 { throw ProviderError.apiMessage("蓝奏云请求过于频繁，请稍后再试") }
                continue
            }
            retries = 0
            if zt == 2 { return all }
            if zt == 3 { throw ProviderError.apiMessage("蓝奏云提取码错误") }
            guard zt == 1 else { throw ProviderError.apiMessage("蓝奏云文件夹解析失败（zt=\(zt)）") }

            guard let arr = json["text"] as? [[String: Any]], !arr.isEmpty else { break }
            var added = 0
            for item in arr {
                let reference = item["id"] as? String ?? ""
                guard !reference.isEmpty else { continue }
                let id = reference.split(separator: "?", maxSplits: 1).first.map(String.init) ?? reference
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                let name = firstNonEmpty(item["name_all"] as? String, item["name"] as? String)
                all.append(ShareFile(
                    fid: id,
                    fname: name.isEmpty ? id : name,
                    fsize: parseDisplaySize(item["size"] as? String ?? ""),
                    isdir: false,
                    pdirFid: "",
                    fidToken: reference.contains("?") ? "\(page.baseUrl)/\(reference)" : "",
                    modifyTime: item["time"] as? String ?? ""
                ))
                added += 1
            }
            if added == 0 { break }
            pg += 1
        }
        return all
    }

    // MARK: - 直链解析（支持文件夹成员二次落地 + iframe + ajaxm/ajaxfile + 节点探测）

    private func resolveDirectLink(page: LanzouSharePage, file: ShareFile, pwd: String?) async throws -> DownloadLink {
        let origin = page.baseUrl
        let memberUrl = file.fidToken.isEmpty ? nil : file.fidToken
        var referer = memberUrl ?? page.shareUrl
        var html: String
        if let memberUrl {
            html = try await fetchPageFollowingLanzou(memberUrl)
        } else {
            html = page.html
        }

        // 同源 iframe 下载页
        if let iframeRaw = firstCapture(pattern: #"<iframe[^>]+src=["']([^"']+)["']"#, in: html) {
            let iframeUrl = absolutize(base: origin, target: iframeRaw)
            if let iframeHost = URL(string: iframeUrl)?.host,
               let refHost = URL(string: referer)?.host,
               iframeHost.caseInsensitiveCompare(refHost) == .orderedSame {
                html = try await fetchText(url: iframeUrl, referer: referer)
                referer = iframeUrl
            }
        }

        let fileId = page.fileId
            ?? firstCapture(pattern: #"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? firstCapture(pattern: #"file=(\d+)"#, in: html)
            ?? ""
        guard !fileId.isEmpty else {
            throw ProviderError.missingData("未能解析蓝奏云文件下载参数")
        }

        let passwordRequired = page.needsPwd || html.contains("function down_p(")
        if passwordRequired && (pwd?.isEmpty ?? true) {
            throw ProviderError.apiMessage("该文件需要提取码")
        }
        let withPwd = passwordRequired && !(pwd?.isEmpty ?? true)
        let ajaxUrl = resolveAjaxURL(html: html, origin: origin, fileId: fileId, withPwd: withPwd)

        let downData = extractDataObjects(in: html).last {
            $0["action"] == "downprocess" && !($0["sign"] ?? "").isEmpty
        }
        guard let sign = downData?["sign"]
            ?? jsVar(in: html, name: "wp_sign")
            ?? jsVar(in: html, name: "sign")
            ?? inputValue(in: html, name: "sign"), !sign.isEmpty else {
            throw ProviderError.missingData("蓝奏云页面缺少 sign 下载参数")
        }

        var fields: [(String, String)] = [
            ("action", "downprocess"),
            ("sign", sign)
        ]
        if withPwd, let pwd {
            fields.append(("p", pwd))
            fields.append(("kd", "1"))
        } else {
            let ajaxData = jsVar(in: html, name: "ajaxdata") ?? downData?["signs"] ?? ""
            let key = nonEmpty(downData?["websignkey"])
                ?? nonEmpty(ajaxData)
                ?? jsVar(in: html, name: "websignkey")
                ?? inputValue(in: html, name: "websignkey")
                ?? ""
            guard !key.isEmpty else {
                throw ProviderError.missingData("蓝奏云页面缺少 websignkey 下载参数")
            }
            if !ajaxData.isEmpty { fields.append(("signs", ajaxData)) }
            fields.append(("websignkey", key))
            fields.append(("websign", downData?["websign"] ?? jsVar(in: html, name: "websign") ?? ""))
            fields.append(("kd", "1"))
            fields.append(("ves", "1"))
        }

        let ajaxJson = try await formPostJSON(url: ajaxUrl, fields: fields, referer: referer, origin: origin)
        let zt = (ajaxJson["zt"] as? NSNumber)?.intValue ?? 0
        if zt != 1 {
            let inf = ajaxJson["inf"] as? String ?? ""
            if inf.contains("密码") || inf.contains("提取码") {
                throw ProviderError.apiMessage("蓝奏云提取码错误")
            }
            throw ProviderError.apiMessage(inf.isEmpty ? "蓝奏云直链解析失败" : inf)
        }

        let dom = ajaxJson["dom"] as? String ?? ""
        let rel = ajaxJson["url"] as? String ?? ""
        guard !dom.isEmpty, !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("://"),
              let domUri = URL(string: dom), let domScheme = domUri.scheme, let domHost = domUri.host else {
            throw ProviderError.missingData("蓝奏云返回的下载地址格式异常")
        }

        let jumpUrl = "\(domScheme)://\(domHost)/file/\(rel)"
        let (finalUrl, size) = try await probeAndVerify(jumpUrl: jumpUrl, shareOrigin: origin)
        let fileName = file.fname.isEmpty ? (ajaxJson["inf"] as? String ?? "蓝奏文件") : file.fname
        return DownloadLink(fid: file.fid, filename: fileName, downloadUrl: finalUrl, size: size > 0 ? size : file.fsize)
    }

    private func probeAndVerify(jumpUrl: String, shareOrigin: String) async throws -> (String, Int64) {
        var current = jumpUrl
        if let host = URL(string: jumpUrl)?.host {
            setCookie(host: host, name: "down_ip", value: "1")
        }
        var visited: Set<String> = []
        var challenged: Set<String> = []
        var confirmed: Set<String> = []

        for _ in 0..<8 {
            guard let uri = URL(string: current), let scheme = uri.scheme, let host = uri.host else {
                throw ProviderError.missingData("蓝奏云下载节点地址不可用")
            }
            guard visited.insert(current).inserted else {
                throw ProviderError.apiMessage("蓝奏云下载链接出现循环跳转")
            }

            var headers = [
                "User-Agent": LanzouConstants.webUA,
                "Referer": "\(shareOrigin)/"
            ]
            let cookie = mergedCookie(host: host, extra: LanzouConstants.downIPCookie)
            if !cookie.isEmpty { headers["Cookie"] = cookie }

            let resp = try await http.send(url: current, method: "HEAD", headers: headers, followRedirects: false)
            if (300..<400).contains(resp.statusCode), let loc = resp.header("Location"), !loc.isEmpty {
                current = absolutize(base: "\(scheme)://\(host)", target: loc)
                continue
            }

            if resp.statusCode == 200 || resp.statusCode == 206 {
                let ct = resp.header("Content-Type") ?? ""
                if ct.lowercased().contains("text/html") {
                    let body = try await fetchText(url: current, referer: "\(shareOrigin)/", extraCookie: LanzouConstants.downIPCookie)
                    if let challenge = LanzouChallenge.extractChallengeCookie(from: body) {
                        guard challenged.insert(host).inserted else {
                            throw ProviderError.apiMessage("蓝奏云下载节点触发人机校验，请稍后重试")
                        }
                        setCookie(host: host, name: "acw_sc__v2", value: challenge)
                        visited.remove(current)
                        continue
                    }
                    if body.contains("验证并下载"), confirmed.insert(host).inserted,
                       let verified = try await submitVerifyPage(nodeUrl: current, html: body) {
                        current = verified
                        continue
                    }
                    throw ProviderError.apiMessage("蓝奏云节点要求网页验证，请稍后重试")
                }

                let size = Int64(resp.header("Content-Length") ?? "") ?? 0
                return (current, size)
            }

            if resp.statusCode == 403 || resp.statusCode == 404 || resp.statusCode == 410 {
                throw ProviderError.apiMessage("蓝奏云下载直链已失效，请重新解析")
            }
            if resp.statusCode == 429 {
                throw ProviderError.apiMessage("蓝奏云下载请求过于频繁，请稍后重试")
            }
            throw ProviderError.apiMessage("蓝奏云下载节点不可用（HTTP \(resp.statusCode)）")
        }
        throw ProviderError.apiMessage("蓝奏云下载节点跳转次数过多")
    }

    private func submitVerifyPage(nodeUrl: String, html: String) async throws -> String? {
        guard let uri = URL(string: nodeUrl), let scheme = uri.scheme, let host = uri.host else { return nil }
        let fileVal = firstCapture(pattern: #"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#, in: html)
            ?? inputValue(in: html, name: "file")
        let signVal = firstCapture(pattern: #"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#, in: html)
            ?? jsVar(in: html, name: "sign")
            ?? inputValue(in: html, name: "sign")
        guard let fileVal, let signVal else { return nil }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let ajaxUrl = "\(scheme)://\(host)/ajax.php"
        let json = try await formPostJSON(
            url: ajaxUrl,
            fields: [("file", fileVal), ("el", "2"), ("sign", signVal)],
            referer: nodeUrl,
            origin: "\(scheme)://\(host)"
        )
        let zt = (json["zt"] as? NSNumber)?.intValue ?? 0
        let url = json["url"] as? String ?? ""
        guard zt == 1, !url.isEmpty, url != "?SignError" else { return nil }
        return url
    }

    // MARK: - 页面抓取与 HTML/JS 解析辅助

    private func fetchPageFollowingLanzou(_ url: String) async throws -> String {
        var current = url
        var challenged: Set<String> = []

        for _ in 0..<8 {
            let host = URL(string: current)?.host ?? ""
            var headers = [
                "User-Agent": LanzouConstants.webUA,
                "Referer": current
            ]
            let c = cookieHeader(for: host)
            if !c.isEmpty { headers["Cookie"] = c }

            let resp = try await http.send(url: current, method: "GET", headers: headers, followRedirects: false)
            if (300..<400).contains(resp.statusCode), let loc = resp.header("Location"), !loc.isEmpty {
                let next = absolutize(base: current, target: loc)
                guard let nextHost = URL(string: next)?.host, LanzouConstants.isLanzouHost(nextHost) else {
                    throw ProviderError.apiMessage("蓝奏云分享链接无效或已跳转至外部地址")
                }
                current = next
                continue
            }
            let body = resp.text
            if let challenge = LanzouChallenge.extractChallengeCookie(from: body) {
                guard challenged.insert(host).inserted else {
                    throw ProviderError.apiMessage("蓝奏云人机校验未通过，请稍后重试")
                }
                setCookie(host: host, name: "acw_sc__v2", value: challenge)
                continue
            }
            if body.contains("文件已取消") || body.contains("不存在") {
                throw ProviderError.apiMessage("该蓝奏云分享已取消或不存在")
            }
            if body.contains("请求过于频繁") || body.contains("稍后再试") {
                throw ProviderError.apiMessage("蓝奏云请求过于频繁，请稍后重试")
            }
            return body
        }
        throw ProviderError.apiMessage("蓝奏云分享重定向次数过多")
    }

    private func fetchText(url: String, referer: String, extraCookie: String? = nil) async throws -> String {
        let host = URL(string: url)?.host ?? ""
        var headers = [
            "User-Agent": LanzouConstants.webUA,
            "Referer": referer
        ]
        let cookie = mergedCookie(host: host, extra: extraCookie)
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let resp = try await http.send(url: url, method: "GET", headers: headers)
        guard resp.isSuccessful else {
            throw ProviderError.apiMessage("蓝奏云页面加载失败（HTTP \(resp.statusCode)）")
        }
        return resp.text
    }

    private func formPostJSON(
        url: String,
        fields: [(String, String)],
        referer: String,
        origin: String
    ) async throws -> [String: Any] {
        let host = URL(string: url)?.host ?? ""
        let encoded = fields.map { k, v -> String in
            let ek = formEncode(k)
            let ev = formEncode(v)
            return "\(ek)=\(ev)"
        }.joined(separator: "&")

        var headers = [
            "User-Agent": LanzouConstants.webUA,
            "Referer": referer,
            "Origin": origin,
            "X-Requested-With": "XMLHttpRequest",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"
        ]
        let c = cookieHeader(for: host)
        if !c.isEmpty { headers["Cookie"] = c }

        let resp = try await http.send(url: url, method: "POST", headers: headers, body: Data(encoded.utf8), followRedirects: false)
        guard let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] else {
            throw ProviderError.apiMessage("蓝奏云接口返回非 JSON 响应（可能触发风控）")
        }
        return json
    }

    private func resolveAjaxURL(html: String, origin: String, fileId: String, withPwd: Bool) -> String {
        if let fromScript = firstCapture(
            pattern: #"['"]?url['"]?\s*:\s*['"]((?:\./)?[^'"]*ajax(?:m|file)\.php\?file=\d+[^'"]*)['"]"#,
            in: html
        ), !fromScript.isEmpty {
            return absolutize(base: origin, target: fromScript)
        }
        if let d1 = jsVar(in: html, name: "domain1"), d1.contains("/ajax") { return d1 }
        if let d2 = jsVar(in: html, name: "domain2"), d2.contains("/ajax") { return d2 }
        if let abs = firstMatch(pattern: #"https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+"#, in: html) {
            return abs
        }
        return withPwd ? "\(origin)/ajaxfile.php?file=\(fileId)" : "\(origin)/ajaxm.php?file=\(fileId)"
    }

    private func extractDataObjects(in html: String) -> [[String: String]] {
        guard let regex = try? NSRegularExpression(pattern: #"\bdata\s*:\s*\{([^{}]*)\}"#, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { return nil }
            return parseJSProperties(String(html[r]), page: html)
        }
    }

    private func parseJSProperties(_ source: String, page: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:['"]([A-Za-z_]\w*)['"]|([A-Za-z_]\w*))\s*:\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\d+)"#
        ) else {
            return [:]
        }
        var out: [String: String] = [:]
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, options: [], range: range) {
            let k1 = match.range(at: 1).location != NSNotFound ? Range(match.range(at: 1), in: source).map { String(source[$0]) } : nil
            let k2 = match.range(at: 2).location != NSNotFound ? Range(match.range(at: 2), in: source).map { String(source[$0]) } : nil
            guard let key = nonEmpty(k1) ?? nonEmpty(k2),
                  let vr = Range(match.range(at: 3), in: source) else { continue }
            let raw = String(source[vr])
            if (raw.hasPrefix("'") && raw.hasSuffix("'")) || (raw.hasPrefix("\"") && raw.hasSuffix("\"")) {
                out[key] = String(raw.dropFirst().dropLast())
            } else if raw.allSatisfy(\.isNumber) {
                out[key] = raw
            } else if let resolved = jsVar(in: page, name: raw) {
                out[key] = resolved
            }
        }
        return out
    }

    private func extractTitle(from html: String) -> String {
        if let t = firstCapture(pattern: #"<title>([^<]*)</title>"#, in: html) {
            let clean = t.replacingOccurrences(of: " - 蓝奏云", with: "")
                .replacingOccurrences(of: "蓝奏云", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !clean.contains("密码") { return clean }
        }
        if let n = firstCapture(pattern: #"class=["']n["']>([^<]+)<"#, in: html) {
            return n.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let f = firstCapture(pattern: #"var\s+filename\s*=\s*['"]([^'"]+)['"]"#, in: html) {
            return f
        }
        return ""
    }

    private func jsVar(in html: String, name: String) -> String? {
        firstCapture(pattern: #"(?:(?:var|let|const)\s+)?\#(name)\s*=\s*['"]([^'"]*)['"]"#, in: html)
    }

    private func inputValue(in html: String, name: String) -> String? {
        firstCapture(pattern: #"<input[^>]*name=["']\#(name)["'][^>]*value=["']([^"']*)["']"#, in: html)
            ?? firstCapture(pattern: #"<input[^>]*value=["']([^"']*)["'][^>]*name=["']\#(name)["']"#, in: html)
    }

    private func absolutize(base: String, target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        guard let baseURL = URL(string: base), let scheme = baseURL.scheme, let host = baseURL.host else { return target }
        let root = "\(scheme)://\(host)"
        if target.hasPrefix("//") { return "\(scheme):\(target)" }
        if target.hasPrefix("/") { return root + target }
        if target.hasPrefix("?") { return root + baseURL.path + target }
        return URL(string: target, relativeTo: URL(string: "\(root)/"))?.absoluteString ?? "\(root)/\(target)"
    }

    private func parseDisplaySize(_ text: String) -> Int64 {
        guard let captures = allCaptures(pattern: #"([\d.]+)\s*([KMGT]?)"#, in: text),
              captures.count >= 1,
              let value = Double(captures[0]) else {
            return 0
        }
        let unit = captures.count >= 2 ? captures[1].uppercased() : ""
        let factor: Double
        switch unit {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default: factor = 1
        }
        return Int64(value * factor)
    }

    private func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func setCookie(host: String, name: String, value: String) {
        guard !host.isEmpty else { return }
        lock.lock()
        var map = hostCookies[host] ?? [:]
        map[name] = value
        hostCookies[host] = map
        lock.unlock()
    }

    private func cookieHeader(for host: String) -> String {
        lock.lock()
        let map = hostCookies[host] ?? [:]
        lock.unlock()
        return map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func mergedCookie(host: String, extra: String?) -> String {
        CookieHelper.join(cookieHeader(for: host), extra ?? "")
    }

    private func cachePage(_ page: LanzouSharePage) {
        lock.lock()
        pageCache[page.shareUrl] = page
        lock.unlock()
    }

    private func cachedPage(for shareUrl: String) -> LanzouSharePage? {
        lock.lock()
        defer { lock.unlock() }
        return pageCache[shareUrl]
    }

    private func firstNonEmpty(_ a: String?, _ b: String?) -> String {
        if let a, !a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return a.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let b, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return b.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        allCaptures(pattern: pattern, in: text)?.first
    }

    private func allCaptures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range), m.numberOfRanges > 1 else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            let nr = m.range(at: i)
            if nr.location != NSNotFound, let r = Range(nr, in: text) {
                out.append(String(text[r]))
            }
        }
        return out
    }
}
