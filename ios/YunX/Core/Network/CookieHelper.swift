//
//  CookieHelper.swift
//  YunX
//
//  Cookie 解析、合并与续期工具（与 Android QuarkCookieUtil / UCCookieUtil 一致）。
//

import Foundation

public enum CookieHelper {
    /// 夸克/UC 需要持续跟踪并回写的会话字段
    public static let quarkTrackedKeys: Set<String> = ["__puus", "__pus"]

    /// 把响应 Set-Cookie 中指定键合并回原 Cookie 串
    public static func merge(original: String, setCookies: [String], trackedKeys: Set<String> = quarkTrackedKeys) -> String {
        var current = original
        for sc in setCookies {
            let pair = sc.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...])
            if trackedKeys.contains(name), !value.isEmpty {
                current = setOrReplace(cookie: current, name: name, value: value)
            }
        }
        return current
    }

    /// 剥离 __puus（用于请求 /config 触发服务端重新下发新鲜 __puus）
    public static func withoutPuus(_ cookie: String) -> String {
        cookie
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("__puus=") }
            .joined(separator: "; ")
    }

    /// 从 Set-Cookie 提取游客态令牌 `__pugs=...`
    public static func extractPugs(from setCookies: [String]) -> String? {
        for sc in setCookies {
            let pair = sc.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if pair.hasPrefix("__pugs="), pair.count > "__pugs=".count {
                return pair
            }
        }
        return nil
    }

    /// 按键名读取 Cookie 值
    public static func value(for name: String, in cookie: String) -> String? {
        let prefix = "\(name)="
        for part in cookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                let val = String(trimmed.dropFirst(prefix.count))
                return val.isEmpty ? nil : val
            }
        }
        return nil
    }

    /// 合并多段 Cookie 串（忽略空串）
    public static func join(_ parts: String...) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
    }

    private static func setOrReplace(cookie: String, name: String, value: String) -> String {
        var parts = cookie
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let prefix = "\(name)="
        let kv = "\(name)=\(value)"
        if let idx = parts.firstIndex(where: { $0.hasPrefix(prefix) }) {
            parts[idx] = kv
        } else {
            parts.append(kv)
        }
        return parts.joined(separator: "; ")
    }
}
