//
//  AppTheme.swift
//  YunX
//
//  统一设计令牌、品牌色扩展与可读字节/速度/时长格式化工具。
//

import SwiftUI

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    static let yunxBrand = Color(hex: 0x4C8BF5)
    static let yunxSuccess = Color(hex: 0x16A34A)
    static let yunxWarning = Color(hex: 0xEA580C)
}

public enum Formatters {
    public static func fileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "未知大小" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return idx == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[idx])
    }

    public static func speed(_ bytesPerSec: Int64) -> String {
        guard bytesPerSec > 0 else { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = Double(bytesPerSec)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return idx == 0 ? "\(bytesPerSec) B/s" : String(format: "%.1f %@", value, units[idx])
    }

    public static func remainingTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds)
        if total < 60 { return "\(total) 秒" }
        let mins = total / 60
        let secs = total % 60
        if mins < 60 { return "\(mins) 分 \(secs) 秒" }
        let hours = mins / 60
        let remMins = mins % 60
        return "\(hours) 时 \(remMins) 分"
    }
}
