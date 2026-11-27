//
//  AboutView.swift
//  YunX
//
//  关于云析 iOS 版：展示架构特点、致谢上游开源仓库 CYQawa/YunX 与 AGPL-3.0 协议。
//

import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.yunxBrand.gradient)
                            .frame(width: 76, height: 76)
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(.white)
                    }
                    Text("云析 · YunX iOS")
                        .font(.title2.bold())
                    Text("v1.0.0 (Phase 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("基于 CYQawa/YunX 移植的原生 SwiftUI iOS 高速网盘解析下载客户端")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("开源与隐私声明") {
                LabeledContent("开源协议", value: "GNU AGPL-3.0")
                LabeledContent("运行模式", value: "100% 本地直连，无中转服务器")
                LabeledContent("凭证存储", value: "iOS 系统 Keychain")
                Link(destination: URL(string: "https://github.com/qbqbqb666/YunX-ios")!) {
                    Label("本项目仓库 (qbqbqb666/YunX-ios)", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/CYQawa/YunX")!) {
                    Label("致谢上游原项目 (CYQawa/YunX)", systemImage: "heart.fill")
                }
            }

            Section("下载文件保存位置") {
                Text("下载完成的文件默认保存在「文件」App → 我的 iPhone → 云析 → YunXDownloads 目录中，可随时 AirDrop 或用第三方应用打开。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于云析")
        .navigationBarTitleDisplayMode(.inline)
    }
}
