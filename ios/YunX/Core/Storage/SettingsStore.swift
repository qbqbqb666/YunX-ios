//
//  SettingsStore.swift
//  YunX
//
//  全局应用设置唯一入口（对应 Android SettingsRepository.kt）。
//

import Foundation
import Observation
import SwiftUI

public enum AppAppearance: Int, CaseIterable, Identifiable, Sendable {
    case system = 0
    case light = 1
    case dark = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "始终浅色"
        case .dark: return "始终深色"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
@Observable
public final class SettingsStore {
    public static let defaultThreads = 16
    public static let maxThreads = 64
    public static let xunleiFixedThreads = 8
    public static let defaultMaxConcurrentDownloads = 3

    private let defaults: UserDefaults

    public var defaultDownloadThreads: Int {
        didSet {
            let clamped = min(max(defaultDownloadThreads, 1), Self.maxThreads)
            if clamped != defaultDownloadThreads { defaultDownloadThreads = clamped; return }
            defaults.set(clamped, forKey: Keys.defaultThreads)
        }
    }

    public var maxConcurrentDownloads: Int {
        didSet {
            let clamped = min(max(maxConcurrentDownloads, 1), 8)
            if clamped != maxConcurrentDownloads { maxConcurrentDownloads = clamped; return }
            defaults.set(clamped, forKey: Keys.maxConcurrent)
        }
    }

    /// 全局限速（字节/秒；0 = 不限速）
    public var speedLimitBytesPerSec: Int64 {
        didSet {
            let clamped = max(0, speedLimitBytesPerSec)
            if clamped != speedLimitBytesPerSec { speedLimitBytesPerSec = clamped; return }
            defaults.set(clamped, forKey: Keys.speedLimit)
        }
    }

    /// 夸克登录态默认免转存直接取链（失败自动回退临时转存）
    public var quarkNoSaveDownload: Bool {
        didSet { defaults.set(quarkNoSaveDownload, forKey: Keys.quarkNoSave) }
    }

    /// 前台下载时防息屏常亮（iOS 高速多线程防后台挂起核心设置）
    public var keepScreenAwakeWhileDownloading: Bool {
        didSet { defaults.set(keepScreenAwakeWhileDownloading, forKey: Keys.keepAwake) }
    }

    /// 自动检测剪贴板分享链接
    public var clipboardDetectEnabled: Bool {
        didSet { defaults.set(clipboardDetectEnabled, forKey: Keys.clipboardDetect) }
    }

    /// 文件名多行展示
    public var fileNameMultiLine: Bool {
        didSet { defaults.set(fileNameMultiLine, forKey: Keys.fileNameMultiLine) }
    }

    /// 浅色 / 深色 / 跟随系统
    public var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    private enum Keys {
        static let defaultThreads = "yunx.settings.default_threads"
        static let maxConcurrent = "yunx.settings.max_concurrent"
        static let speedLimit = "yunx.settings.speed_limit"
        static let quarkNoSave = "yunx.settings.quark_no_save"
        static let keepAwake = "yunx.settings.keep_awake"
        static let clipboardDetect = "yunx.settings.clipboard_detect"
        static let fileNameMultiLine = "yunx.settings.filename_multiline"
        static let appearance = "yunx.settings.appearance"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedThreads = defaults.object(forKey: Keys.defaultThreads) as? Int ?? Self.defaultThreads
        self.defaultDownloadThreads = min(max(savedThreads, 1), Self.maxThreads)
        let savedConcurrent = defaults.object(forKey: Keys.maxConcurrent) as? Int ?? Self.defaultMaxConcurrentDownloads
        self.maxConcurrentDownloads = min(max(savedConcurrent, 1), 8)
        self.speedLimitBytesPerSec = max(0, Int64(defaults.integer(forKey: Keys.speedLimit)))
        self.quarkNoSaveDownload = defaults.object(forKey: Keys.quarkNoSave) as? Bool ?? true
        self.keepScreenAwakeWhileDownloading = defaults.object(forKey: Keys.keepAwake) as? Bool ?? true
        self.clipboardDetectEnabled = defaults.object(forKey: Keys.clipboardDetect) as? Bool ?? true
        self.fileNameMultiLine = defaults.object(forKey: Keys.fileNameMultiLine) as? Bool ?? false
        let rawAppearance = defaults.integer(forKey: Keys.appearance)
        self.appearance = AppAppearance(rawValue: rawAppearance) ?? .system
    }

    /// 按平台返回生效的分片并发线程数（迅雷按原项目规则固定 8 防止 CDN 200 降级）
    public func threads(for platform: DownloadPlatform) -> Int {
        if platform == .xunlei {
            return Self.xunleiFixedThreads
        }
        return defaultDownloadThreads
    }
}
