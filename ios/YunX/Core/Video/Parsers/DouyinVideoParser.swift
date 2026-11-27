//
//  DouyinVideoParser.swift
//  YunX
//
//  抖音视频/图文解析器：
//  - 主路径：离屏 WKWebView 自动过 byted_acrawler 挑战 + XHR 详情钩子 + SSR #RENDER_DATA 抽取无水印视频/原图/动图；
//  - 兜底路径：HTTP SSR window._ROUTER_DATA + aweme/v1/play 清晰度探测。
//

import Foundation

public struct DouyinVideoParser: VideoParser, Sendable {
    public let platform: VideoPlatform = .douyin

    private static let iesReferer = "https://www.iesdouyin.com/"
    private static let playRatios = ["1080p", "720p", "540p", "360p"]

    public init() {}

    public func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        // 1. 主路径：离屏 WKWebView 过 JS 挑战并从详情响应 / SSR 提取
        if let webResult = await fetchViaWebView(link: link) {
            return webResult
        }

        // 2. 兜底路径：直接拉取分享页 _ROUTER_DATA
        let shareURL = "https://www.iesdouyin.com/share/\(pathType(link: link))/\(link.id)/"
        var headers: [String: String] = [
            "User-Agent": VideoHTTP.uaIPhone,
            "Referer": Self.iesReferer
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let html = try await VideoHTTP.getText(url: shareURL, headers: headers, what: "抖音分享页")
        guard let routerRaw = VideoHTTP.extractInlineJSON(html: html, key: "window._ROUTER_DATA"),
              let routerData = routerRaw.data(using: .utf8),
              let router = try? JSONSerialization.jsonObject(with: routerData) as? [String: Any],
              let loader = router["loaderData"] as? [String: Any],
              let page = (loader["video_(id)/page"] as? [String: Any]) ?? (loader["note_(id)/page"] as? [String: Any]),
              let infoRes = (page["videoInfoRes"] as? [String: Any]) ?? (page["video_info_res"] as? [String: Any]),
              let items = (infoRes["item_list"] as? [[String: Any]]) ?? (infoRes["itemList"] as? [[String: Any]]),
              let item = items.first else {
            throw VideoParseError(.blocked, "抖音页面未返回作品数据（可能触发验证，请稍后重试）")
        }

        let mediaHeaders = [
            "User-Agent": VideoHTTP.uaIPhone,
            "Referer": shareURL
        ]
        let title = VideoHTTP.str(item["desc"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "douyin_\(link.id)")
        var medias: [VideoMedia] = []
        var cover = ""

        if let images = item["images"] as? [[String: Any]], !images.isEmpty {
            for (idx, img) in images.enumerated() {
                guard let url = firstURL(from: img) else { continue }
                if cover.isEmpty { cover = url }
                medias.append(VideoMedia(
                    url: url,
                    kind: .image,
                    fileName: "\(base)_\(idx + 1).jpg",
                    headers: mediaHeaders,
                    quality: "原图"
                ))
            }
        } else if let video = item["video"] as? [String: Any] {
            let playAddr = (video["play_addr"] as? [String: Any]) ?? (video["playAddr"] as? [String: Any])
            let rawUrl = firstURL(from: playAddr)?.replacingOccurrences(of: "/playwm/", with: "/play/") ?? ""
            if !rawUrl.isEmpty {
                cover = firstURL(from: video["cover"] as? [String: Any]) ?? ""
                medias.append(VideoMedia(
                    url: rawUrl,
                    kind: .video,
                    fileName: "\(base).mp4",
                    headers: mediaHeaders,
                    quality: "无水印"
                ))
            }
        }

        guard !medias.isEmpty else {
            throw VideoParseError(.notFound, "抖音作品未包含可下载的视频或图片")
        }
        let author = item["author"] as? [String: Any]
        return VideoParseResult(
            platform: .douyin,
            title: title,
            author: VideoHTTP.str(author?["nickname"]),
            avatar: firstURL(from: author?["avatar_thumb"] as? [String: Any]) ?? "",
            cover: cover,
            text: title,
            timestampSeconds: VideoHTTP.int64(item["create_time"]),
            url: link.url,
            medias: medias
        )
    }

    private func fetchViaWebView(link: DetectedVideoLink) async -> VideoParseResult? {
        let targetURL = "https://www.douyin.com/\(pathType(link: link))/\(link.id)"
        guard let rawJSON = await HeadlessWebExtractor.loadAndExtract(
            url: targetURL,
            userAgent: VideoHTTP.uaChrome,
            readyCheckJS: Self.readyCheckJS,
            extractJS: Self.extractJS,
            documentStartScripts: [Self.xhrDetailHookJS],
            timeoutSeconds: 32
        ),
              let data = rawJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let images = (obj["images"] as? [String] ?? []).filter { !$0.isEmpty }
        let motions = (obj["motions"] as? [String] ?? [])
        let video = VideoHTTP.str(obj["video"])
        guard !images.isEmpty || !video.isEmpty else { return nil }

        let title = VideoHTTP.str(obj["title"])
        let desc = VideoHTTP.str(obj["desc"])
        let author = VideoHTTP.str(obj["author"])
        let cover = VideoHTTP.str(obj["cover"])
        let base = VideoHTTP.sanitizeFileName(title, fallback: "douyin_\(link.id)")
        let mediaHeaders = [
            "User-Agent": VideoHTTP.uaIPhone,
            "Referer": "https://www.douyin.com/"
        ]

        var medias: [VideoMedia] = []
        if !images.isEmpty {
            for (idx, imgURL) in images.enumerated() {
                let motion = idx < motions.count ? motions[idx] : ""
                let ext = Self.imageExtension(for: imgURL)
                medias.append(VideoMedia(
                    url: imgURL,
                    kind: .image,
                    fileName: "\(base)_\(idx + 1)\(ext)",
                    headers: mediaHeaders,
                    quality: motion.isEmpty ? "原图" : "实况图",
                    motionUrl: motion
                ))
            }
        } else {
            medias.append(VideoMedia(
                url: video,
                kind: .video,
                fileName: "\(base).mp4",
                headers: mediaHeaders,
                quality: "无水印"
            ))
        }

        return VideoParseResult(
            platform: .douyin,
            title: title,
            author: author,
            cover: cover.isEmpty ? (images.first ?? "") : cover,
            text: desc.isEmpty ? title : desc,
            url: link.url,
            medias: medias
        )
    }

    private func pathType(link: DetectedVideoLink) -> String {
        link.url.lowercased().contains("/note/") ? "note" : "video"
    }

    private func firstURL(from node: [String: Any]?) -> String? {
        guard let node else { return nil }
        let list = (node["url_list"] as? [String]) ?? (node["urlList"] as? [String]) ?? []
        return list.first(where: { !$0.isEmpty })
    }

    private static func imageExtension(for url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".webp") { return ".webp" }
        if lower.contains(".png") { return ".png" }
        return ".jpg"
    }

    private static let xhrDetailHookJS = """
    (function () {
      try {
        if (window.__yunxDetailHookInstalled) return;
        window.__yunxDetailHookInstalled = true;
        var rawOpen = XMLHttpRequest.prototype.open;
        var rawSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
          try { this.__yunxUrl = String(url || ''); } catch (e) { this.__yunxUrl = ''; }
          return rawOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
          var xhr = this;
          try {
            xhr.addEventListener('load', function () {
              try {
                var url = xhr.__yunxUrl || '';
                if (url.indexOf('aweme/v1/web/aweme/detail') < 0) return;
                if (xhr.status !== 200) return;
                var text = '';
                try { text = xhr.responseText || ''; } catch (e) { text = ''; }
                if (!text && xhr.response) {
                  text = (typeof xhr.response === 'string') ? xhr.response : JSON.stringify(xhr.response);
                }
                if (text) window.__yunxAwemeDetail = text;
              } catch (e) {}
            });
          } catch (e) {}
          return rawSend.apply(this, arguments);
        };
      } catch (e) {}
    })();
    """

    private static let readyCheckJS = """
    (function () {
      var raw = window.__yunxAwemeDetail;
      if (typeof raw === 'string' && raw.length > 0) return 'true';
      var imgs = document.querySelectorAll('img');
      for (var i = 0; i < imgs.length; i++) {
        var s = imgs[i].src || '';
        if (s.indexOf('douyinpic.com') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
            (s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0)) {
          return 'true';
        }
      }
      return 'false';
    })()
    """

    private static let extractJS = """
    (function () {
      try {
        function firstUrl(node) {
          if (!node) return '';
          var list = node.url_list || node.urlList || null;
          if (list && list.length) return String(list[0] || '');
          return '';
        }
        function motionUrl(item) {
          if (!item || !item.video) return '';
          var v = item.video;
          var d = firstUrl(v.playAddr) || firstUrl(v.play_addr) || firstUrl(v.playApi) || firstUrl(v.play_addr_h264);
          if (d) return d;
          var list = v.playAddr || v.play_addr || null;
          if (list && list.length && list[0]) return String(list[0].src || list[0].url || '');
          return '';
        }
        function hookDetail() {
          var raw = window.__yunxAwemeDetail || '';
          if (!raw) return null;
          try {
            var root = JSON.parse(raw);
            return root.aweme_detail || root.awemeDetail || (root.data && root.data.aweme_detail) || null;
          } catch (e) { return null; }
        }
        function readSsrDetail() {
          var node = document.querySelector('#RENDER_DATA');
          if (node && node.textContent) {
            try {
              var app = JSON.parse(decodeURIComponent(node.textContent)).app;
              if (app && app.videoDetail) return app.videoDetail;
            } catch (e) {}
          }
          try {
            var ssr = window.SSR_RENDER_DATA;
            if (ssr && ssr.app && ssr.app.videoDetail) return ssr.app.videoDetail;
          } catch (e) {}
          return null;
        }
        function imagesFrom(node) {
          if (!node || !node.length) return null;
          var list = [], mlist = [];
          for (var i = 0; i < node.length; i++) {
            var item = node[i];
            var u = firstUrl(item) || firstUrl(item.display_image) || firstUrl(item.owner_watermark_image);
            if (u) { list.push(u); mlist.push(motionUrl(item)); }
          }
          return list.length ? { images: list, motions: mlist } : null;
        }
        var hooked = hookDetail();
        var ssr = readSsrDetail();
        var picked = imagesFrom(ssr && ssr.images) || imagesFrom(hooked && hooked.images) || imagesFrom(hooked && hooked.image_post_info && hooked.image_post_info.images);
        var images = picked ? picked.images : [];
        var motions = picked ? picked.motions : [];
        if (!images.length) {
          var all = document.querySelectorAll('img');
          for (var i = 0; i < all.length; i++) {
            var src = all[i].src || '';
            if (src.indexOf('douyinpic') >= 0 && src.indexOf('WEBPC_RELATED') < 0 &&
                (src.indexOf('biz_tag=aweme_images') >= 0 || src.indexOf('tplv-dy-aweme-images') >= 0) &&
                images.indexOf(src) < 0) {
              images.push(src);
            }
          }
        }
        var v = (hooked && hooked.video) || (ssr && ssr.video) || null;
        var video = '';
        if (v) {
          video = firstUrl(v.play_addr) || firstUrl(v.playAddr) || firstUrl(v.play_addr_h264);
          if (!video && v.bit_rate && v.bit_rate.length) {
            for (var j = 0; j < v.bit_rate.length; j++) {
              var c = firstUrl(v.bit_rate[j].play_addr);
              if (c) { video = c; break; }
            }
          }
          video = video.replace('/playwm/', '/play/');
        }
        var d = hooked || ssr;
        var author = (d && d.author && (d.author.nickname || d.author.unique_id)) ||
                     (d && d.authorInfo && (d.authorInfo.nickname || d.authorInfo.nickName)) || '';
        var title = (d && d.desc) || '';
        if (!title) {
          var pt = document.title || '';
          var tail = pt.lastIndexOf(' - 抖音');
          title = tail > 0 ? pt.substring(0, tail) : pt;
        }
        return {
          title: title,
          desc: (d && d.desc) || '',
          author: author,
          video: video,
          images: images,
          motions: motions,
          cover: (v && (firstUrl(v.cover) || firstUrl(v.origin_cover))) || ''
        };
      } catch (e) {
        return { error: String(e) };
      }
    })()
    """
}
