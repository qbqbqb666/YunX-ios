//
//  VideoParserProtocol.swift
//  YunX
//
//  视频/图文解析器公共协议（各平台独立文件实现，职责清晰解耦）。
//

import Foundation

public protocol VideoParser: Sendable {
    var platform: VideoPlatform { get }
    func parse(link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult
    func validateCookie(_ cookie: String) async -> String?
}

public extension VideoParser {
    func validateCookie(_ cookie: String) async -> String? { nil }
}
