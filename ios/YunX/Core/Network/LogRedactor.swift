//
//  LogRedactor.swift
//  YunX
//
//  日志脱敏工具：剥离 URL 查询参数，防止签名/Token 泄漏到控制台或导出日志。
//

import Foundation

public enum LogRedactor {
    public static func redactURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host else {
            return "<redacted-url>"
        }
        return "\(scheme)://\(host)\(url.path)"
    }
}
