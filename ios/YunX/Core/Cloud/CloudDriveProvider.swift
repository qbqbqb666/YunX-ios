//
//  CloudDriveProvider.swift
//  YunX
//
//  个人网盘管理与分享转存统一协议（与 ShareResolveProvider 职责严格分离）。
//

import Foundation

public protocol CloudDriveProvider: Sendable {
    var platform: SharePlatform { get }

    /// 获取个人网盘已用/总容量（不支持或查询失败返回 nil）
    func fetchQuota(credential: String) async -> CloudQuota?

    /// 列出个人网盘指定目录下的全部文件与文件夹
    func listCloudFiles(dirFid: String, credential: String) async throws -> [ShareFile]

    /// 在个人网盘指定父目录下新建文件夹，返回新目录 ID
    func createCloudFolder(parentFid: String, name: String, credential: String) async throws -> String

    /// 重命名个人网盘中的文件或文件夹
    func renameCloudItem(file: ShareFile, newName: String, credential: String) async throws

    /// 移动个人网盘中的一个或多个文件/文件夹到目标目录
    func moveCloudItems(files: [ShareFile], toDirFid: String, credential: String) async throws

    /// 删除个人网盘中的一个或多个文件/文件夹
    func deleteCloudItems(files: [ShareFile], parentFid: String, credential: String) async throws

    /// 为个人网盘中的文件或文件夹创建分享链接
    func createCloudShare(
        files: [ShareFile],
        title: String,
        expire: CloudShareExpire,
        passcode: String?,
        credential: String
    ) async throws -> CloudShareResult

    /// 获取个人网盘文件的真实高速下载直链
    func getCloudDownloadLink(file: ShareFile, credential: String) async throws -> DownloadLink

    /// 上传本地文件到个人网盘指定目录（支持秒传与分片上传，实时回报进度）
    func uploadCloudFile(
        source: UploadSource,
        parentFid: String,
        credential: String,
        onProgress: @escaping @Sendable (UploadProgress) -> Void
    ) async throws -> String?

    /// 将分享页中的文件或文件夹转存到个人网盘指定目录
    func transferShareItem(
        session: ShareSession,
        file: ShareFile,
        toDirFid: String,
        credential: String
    ) async throws
}
