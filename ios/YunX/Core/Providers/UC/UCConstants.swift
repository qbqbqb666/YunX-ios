//
//  UCConstants.swift
//  YunX
//
//  UC 网盘 API 端点与常量（对齐 Android UCConstants.kt）。
//

import Foundation

public enum UCConstants {
    public static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public static let guestUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"

    public static let guestSecChUA = "\"Not=A?Brand\";v=\"99\", \"Chromium\";v=\"100\", \"Google Chrome\";v=\"100\""

    public static let webOrigin = "https://drive.uc.cn"
    public static let downloadReferer = "https://drive.uc.cn/"
    public static let loginURL = "https://drive.uc.cn/"
    public static let cookieDomains = ["drive.uc.cn", "uc.cn", "pc-api.uc.cn"]
    public static let accountInfoURL = "https://drive.uc.cn/account/info"

    public static let apiBase = "https://pc-api.uc.cn"
    public static let shareTokenURL = "\(apiBase)/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
    public static let transferShareDetailURL = "\(apiBase)/1/clouddrive/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser"
    public static let downloadURL = "\(apiBase)/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser"
    public static let videoPreviewURL = "\(apiBase)/1/clouddrive/share/sharepage/video_preview"
    public static let configURL = "\(apiBase)/1/clouddrive/config?pr=UCBrowser&fr=pc"

    public static let defaultPdirFid = "0"

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie else { return false }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }
}
