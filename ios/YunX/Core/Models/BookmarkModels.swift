//
//  BookmarkModels.swift
//  YunX
//
//  分享链接收藏与主页快捷方式模型。
//

import Foundation

public struct BookmarkItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var link: String
    public var title: String
    public var platform: SharePlatform
    public var passcode: String
    public var category: String
    public var homePinned: Bool
    public var homeLabel: String
    public var createdAt: Date

    public static let defaultCategory = "默认收藏"

    public init(
        id: UUID = UUID(),
        link: String,
        title: String,
        platform: SharePlatform,
        passcode: String = "",
        category: String = BookmarkItem.defaultCategory,
        homePinned: Bool = true,
        homeLabel: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.link = link
        self.title = title
        self.platform = platform
        self.passcode = passcode
        self.category = category
        self.homePinned = homePinned
        self.homeLabel = homeLabel
        self.createdAt = createdAt
    }

    /// 主页色块短标签（规则与 Android ResolveScreen.homeTileLabel 一致：自定义 > 标题前4字 > 平台简称）
    public var tileLabel: String {
        let custom = homeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            return String(custom.prefix(4))
        }
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            return String(cleanedTitle.prefix(4))
        }
        return platform.shortLabel
    }
}
