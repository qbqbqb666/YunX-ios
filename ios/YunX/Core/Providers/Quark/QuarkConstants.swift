//
//  QuarkConstants.swift
//  YunX
//
//  夸克网盘 API 端点与常量（对齐 Android QuarkConstants.kt）。
//

import Foundation

public enum QuarkConstants {
    public static let webLoginUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.0.8.649"

    public static let apiUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"

    public static let loginURL = "https://pan.quark.cn/?fr=pc&platform=pc"
    public static let cookieDomains = ["pan.quark.cn", "quark.cn", "drive-pc.quark.cn"]
    public static let accountInfoURL = "https://pan.quark.cn/account/info"

    public static let apiBase = "https://drive-pc.quark.cn"
    public static let shareTokenURL = "\(apiBase)/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
    public static let shareDetailURL = "\(apiBase)/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc"
    public static let downloadURL = "\(apiBase)/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2"
    public static let fileURL = "\(apiBase)/1/clouddrive/file?pr=ucpro&fr=pc"
    public static let saveURL = "\(apiBase)/1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc"
    public static let taskURL = "\(apiBase)/1/clouddrive/task?pr=ucpro&fr=pc"
    public static let deleteURL = "\(apiBase)/1/clouddrive/file/delete?pr=ucpro&fr=pc&uc_param_str="
    public static let configURL = "\(apiBase)/1/clouddrive/config?pr=ucpro&fr=pc"

    public static let defaultPdirFid = "0"
    public static let tempDirName = "YunX临时转存"
    public static let downloadReferer = "https://pan.quark.cn/"

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie else { return false }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }
}
