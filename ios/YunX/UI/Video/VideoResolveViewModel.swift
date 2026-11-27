//
//  VideoResolveViewModel.swift
//  YunX
//
//  视频解析状态机：自动识别 7 大视频平台链接、调用解析服务、单条或批量入队高速下载。
//

import Foundation
import Observation

@MainActor
@Observable
public final class VideoResolveViewModel {
    public var inputText: String = ""
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String?
    public private(set) var result: VideoParseResult?

    private let container: AppContainer

    public var detectedLink: DetectedVideoLink? {
        VideoLinkParser.parse(inputText)
    }

    public init(container: AppContainer) {
        self.container = container
    }

    public func startParse(overrideText: String? = nil) async {
        if let overrideText {
            inputText = overrideText
        }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let parsed = try await container.videoParseService.parse(text: trimmed)
            result = parsed
            if !parsed.notice.isEmpty {
                container.toast.show(parsed.notice)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func reset() {
        result = nil
        errorMessage = nil
    }

    public func downloadMedia(_ media: VideoMedia) {
        let name = media.fileName.isEmpty
            ? "video_\(Int(Date().timeIntervalSince1970)).\(media.kind == .image ? "jpg" : "mp4")"
            : media.fileName
        container.downloadManager.enqueue(
            url: media.url,
            fileName: name,
            headers: media.headers,
            size: max(0, media.size),
            platform: .video
        )
        container.toast.show("已加入高速下载队列")
        container.selectedTab = .download
    }

    public func downloadAllMedias() {
        guard let result, !result.medias.isEmpty else { return }
        for media in result.medias {
            let name = media.fileName.isEmpty
                ? "media_\(Int(Date().timeIntervalSince1970)).\(media.kind == .image ? "jpg" : "mp4")"
                : media.fileName
            container.downloadManager.enqueue(
                url: media.url,
                fileName: name,
                headers: media.headers,
                size: max(0, media.size),
                platform: .video
            )
        }
        container.toast.show("已将 \(result.medias.count) 个媒体加入下载队列")
        container.selectedTab = .download
    }
}
