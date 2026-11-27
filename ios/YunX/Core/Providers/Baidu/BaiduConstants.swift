//
//  BaiduConstants.swift
//  YunX
//
//  百度网盘协议常量与 Cookie 校验工具。
//

import Foundation

public enum BaiduConstants {
    public static let loginURL = "https://pan.baidu.com/"
    public static let cookieDomains = ["pan.baidu.com", "baidu.com"]

    public static let uaWeb = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    public static let uaNetdisk = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"
    public static let uaApp = "netdisk;13.15.4;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0;"
    public static let appVersion = "13.15.4"
    public static let appId = "250528"
    public static let tempDirName = "YunX临时转存"

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie, !cookie.isEmpty else { return false }
        return cookie.contains("BDUSS=")
    }
}
