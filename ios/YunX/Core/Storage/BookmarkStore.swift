//
//  BookmarkStore.swift
//  YunX
//
//  分享链接收藏与主页快捷方式持久化存储。
//

import Foundation
import Observation

@MainActor
@Observable
public final class BookmarkStore {
    public private(set) var items: [BookmarkItem] = []

    private let fileURL: URL

    public var homePinnedItems: [BookmarkItem] {
        items.filter(\.homePinned).sorted { $0.createdAt > $1.createdAt }
    }

    public init(directory: URL? = nil) {
        let baseDir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = baseDir.appendingPathComponent("YunX", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.fileURL = appDir.appendingPathComponent("bookmarks.json")
        load()
    }

    public func add(link: String, title: String, platform: SharePlatform, passcode: String = "", homePinned: Bool = true) {
        let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLink.isEmpty else { return }
        if let idx = items.firstIndex(where: { $0.link == trimmedLink }) {
            items[idx].title = title.isEmpty ? items[idx].title : title
            items[idx].passcode = passcode.isEmpty ? items[idx].passcode : passcode
            items[idx].homePinned = homePinned
        } else {
            let item = BookmarkItem(
                link: trimmedLink,
                title: title.isEmpty ? platform.displayName : title,
                platform: platform,
                passcode: passcode,
                homePinned: homePinned
            )
            items.insert(item, at: 0)
        }
        save()
    }

    public func toggleHomePinned(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].homePinned.toggle()
        save()
    }

    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([BookmarkItem].self, from: data) else {
            return
        }
        self.items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
