//
//  FileBadgeView.swift
//  YunX
//
//  可复用 UI 零件：平台徽章、文件类型图标、文件名多行/单行自适应文本。
//

import SwiftUI

struct PlatformBadgeView: View {
    let platform: SharePlatform
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: platform.symbolName)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
            Text(compact ? platform.shortLabel : platform.displayName)
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
        }
        .foregroundStyle(Color(hex: platform.brandHex))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background(Color(hex: platform.brandHex).opacity(0.14), in: Capsule())
    }
}

struct FileTypeIconView: View {
    let fileName: String
    let isDir: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(iconColor.opacity(0.14))
                .frame(width: 42, height: 42)
            Image(systemName: symbolName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }

    private var ext: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    private var symbolName: String {
        if isDir { return "folder.fill" }
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8":
            return "film.fill"
        case "mp3", "flac", "wav", "m4a", "aac", "ogg":
            return "music.note"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
            return "photo.fill"
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        case "txt", "md", "json", "xml", "log", "swift", "kt", "py", "js":
            return "doc.text.fill"
        case "ipa", "apk", "dmg", "exe", "pkg":
            return "shippingbox.fill"
        default:
            return "doc.fill"
        }
    }

    private var iconColor: Color {
        if isDir { return Color(hex: 0xF59E0B) }
        switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8":
            return Color(hex: 0x8B5CF6)
        case "mp3", "flac", "wav", "m4a", "aac", "ogg":
            return Color(hex: 0xEC4899)
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
            return Color(hex: 0x10B981)
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return Color(hex: 0xEA580C)
        case "pdf":
            return Color(hex: 0xEF4444)
        default:
            return .yunxBrand
        }
    }
}

struct FileNameLabel: View {
    let text: String
    let multiLine: Bool

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .lineLimit(multiLine ? 3 : 1)
            .truncationMode(.middle)
    }
}
