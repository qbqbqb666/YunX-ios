//
//  FileThumbnailView.swift
//  YunX
//
//  列表行首缩略图组件：
//  - 底层始终垫着 FileTypeIconView，加载中或失败时平滑回退、无空白跳变；
//  - L1 内存缓存同步命中，快速滚动复用零闪烁；
//  - 关闭缩略图开关或非图片条目时直接展示图标，不触发任何网络请求。
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct FileThumbnailView: View {
    let file: ShareFile
    let enabled: Bool
    var size: CGFloat = 42
    var cornerRadius: CGFloat = 11

    #if canImport(UIKit)
    @State private var loadedImage: UIImage?
    @State private var loadedURL: String?
    #endif

    private var targetPixelSize: Int {
        Int(ceil(size * 3))
    }

    private var activeThumbnail: FileThumbnail? {
        guard enabled,
              !file.isdir,
              let thumb = file.thumbnail,
              ThumbnailLoader.isEligibleImageFile(file.fname) else {
            return nil
        }
        return thumb
    }

    #if canImport(UIKit)
    private var displayImage: UIImage? {
        guard let thumb = activeThumbnail else { return nil }
        if loadedURL == thumb.url, let loadedImage {
            return loadedImage
        }
        return ThumbnailLoader.shared.cachedImage(for: thumb, targetPixelSize: targetPixelSize)
    }
    #endif

    private var taskID: String {
        "\(enabled)|\(file.id)|\(activeThumbnail?.url ?? "")"
    }

    var body: some View {
        ZStack {
            FileTypeIconView(fileName: file.fname, isDir: file.isdir)
            #if canImport(UIKit)
            if let image = displayImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .transition(.opacity)
            }
            #endif
        }
        .frame(width: size, height: size)
        #if canImport(UIKit)
        .animation(.easeInOut(duration: 0.16), value: displayImage != nil)
        .task(id: taskID) {
            guard let thumb = activeThumbnail else {
                loadedImage = nil
                loadedURL = nil
                return
            }
            if let hit = ThumbnailLoader.shared.cachedImage(for: thumb, targetPixelSize: targetPixelSize) {
                loadedImage = hit
                loadedURL = thumb.url
                return
            }
            if loadedURL != thumb.url {
                loadedImage = nil
                loadedURL = nil
            }
            let image = await ThumbnailLoader.shared.loadImage(for: thumb, targetPixelSize: targetPixelSize)
            guard !Task.isCancelled else { return }
            if let image {
                loadedImage = image
                loadedURL = thumb.url
            }
        }
        #endif
    }
}
