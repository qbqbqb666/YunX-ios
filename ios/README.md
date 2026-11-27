# 云析 · YunX iOS（Swift + SwiftUI 原生移植版）

基于开源项目 [CYQawa/YunX](https://github.com/CYQawa/YunX) 二次开发的原生 iOS 客户端，遵循 **GNU AGPL-3.0** 协议开源。

- **最低支持系统**：iOS 17.0+
- **技术栈**：纯 Swift + SwiftUI + `URLSession` + `WKWebView` + `CryptoKit` + `QuickLook`（零第三方重依赖）
- **隐私架构**：100% 本地直连各网盘官方接口，无任何中转服务器；凭证保存在系统 Keychain，并支持与 Android / PC 端 `YUNX_AUTH_V2` 加密备份互通。

## 模块分区说明

```text
ios/
├── YunX.xcodeproj              # Xcode 26 工程（含 YunX + YunXTests 两个 Target）
├── YunX/
│   ├── App/                    # 应用入口与依赖装配容器
│   ├── Core/
│   │   ├── Models/             # 纯数据模型（网盘平台 / 分享会话 / 下载任务 / 书签）
│   │   ├── Parser/             # 全 11 平台分享链接与提取码识别器
│   │   ├── Network/            # 三会话 HTTP 客户端、Cookie 工具、日志脱敏
│   │   ├── Storage/            # Keychain 凭证、账号/设置/书签存储、YUNX_AUTH_V2 加密备份
│   │   ├── Download/           # 70/30 主池弹性区多线程 Range 引擎、慢连接看门狗抢占、边合边删
│   │   ├── Cloud/              # 个人网盘管理协议与配额模型（CloudDriveProvider / CloudQuota）
│   │   └── Providers/          # 10 大平台独立协议目录（各含 +CloudDrive.swift 个人盘与转存扩展）
│   └── UI/
│       ├── Theme/              # 视觉令牌、格式化工具、复用组件
│       ├── Navigation/         # 5 Tab 主容器（解析 / 云盘 / 下载 / 账号 / 设置）与全局 Toast
│       ├── Resolve/            # 链接解析、面包屑浏览、单文件/文件夹下载、分享一键转存
│       ├── Cloud/              # 个人网盘浏览、配额显示、新建文件夹、重命名、删除、直链下载与转存选目录弹窗
│       ├── Account/            # WKWebView 自动抓 Cookie（夸克/UC/115/139/百度）、原生账密/短信直登（123/迅雷/光鸭）、手动凭证兜底
│       ├── Download/           # 实时速度/进度管理、QuickLook 预览、系统分享与「文件」App 集成
│       └── Settings/           # 线程/并发/限速/防息屏设置、加密备份、关于页
└── YunXTests/                  # 单元测试（链接识别 / 加密备份 / 下载算法 / Phase 1-3 协议与个人盘）
```

## 本地构建与运行

1. 使用 Xcode 打开 `ios/YunX.xcodeproj`
2. 在 Signing & Capabilities 中选择你自己的 Team 并按需修改 Bundle Identifier（默认 `com.yunx.ios`）
3. 选择 iOS 模拟器（如 iPhone 17 Pro）或连接真机，按 `Cmd + R` 运行，按 `Cmd + U` 跑全套单元测试。
