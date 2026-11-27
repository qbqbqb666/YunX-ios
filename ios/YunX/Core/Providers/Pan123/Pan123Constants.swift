//
//  Pan123Constants.swift
//  YunX
//
//  123 云盘 API 端点与签名常量（对齐 Android Pan123Constants.kt）。
//

import Foundation

public enum Pan123Constants {
    public static let apiBase = "https://yun.123pan.cn"
    public static let downloadBase = "https://www.123865.com"

    public static let webLoginURL = "https://yun.123pan.cn/"
    public static let signInURL = "https://user.123pan.cn/api/user/sign_in"
    public static let signInOrigin = "https://user.123pan.cn"
    public static let signInReferer = "https://user.123pan.cn/"
    public static let appVersionSignIn = "132"
    public static let localStorageTokenKey = "authorToken"

    public static let shareGetURL = "\(apiBase)/b/api/share/get"
    public static let shareDownloadInfoURL = "\(downloadBase)/b/api/share/download/info"
    public static let fileListURL = "\(apiBase)/b/api/file/list/new"
    public static let fileDownloadInfoURL = "\(apiBase)/api/file/download_info"
    public static let fileTrashURL = "\(apiBase)/b/api/file/trash"
    public static let fileRenameURL = "\(apiBase)/b/api/file/rename"
    public static let fileUploadRequestURL = "\(apiBase)/b/api/file/upload_request"
    public static let userInfoURL = "\(apiBase)/b/api/user/info"

    public static let webUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    public static let dartUA = "Dart/3.12 (dart:io)"

    public static let platformWeb = "web"
    public static let platformAndroid = "android"
    public static let appVersionWeb = "3"
    public static let appVersionAndroid = "39"
    public static let downloadReferer = "https://yun.123pan.cn/"

    public static let signTable = Array("adefghlmyijnopkqrstubcvwsz")
    public static let signOS = "web"
    public static let signVer = "3"
    /// +16 小时 UTC 偏移（57600 秒）
    public static let signOffsetSeconds: Int64 = 57_600

    public static func persistentLoginUUID() -> String {
        let key = "yunx.pan123.login_uuid"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count == 32 {
            return existing
        }
        let hex = Array("0123456789abcdef")
        let generated = String((0..<32).map { _ in hex.randomElement()! })
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}
