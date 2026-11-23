// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
// EVE-O Preview macOS 原生版的包定义。目标划分见 docs/macos/architecture.md 第 3 节。
import PackageDescription

let package = Package(
    name: "EVEOPreview",
    // 最低支持 macOS 14：ScreenCaptureKit 的单窗口过滤器与协作式激活接口都从这一版起可用。
    platforms: [.macOS(.v14)],
    targets: [
        // 纯逻辑层：只 import Foundation，全部可单元测试。
        .target(name: "EVEOPreviewCore"),
        // 平台层：AppKit、ScreenCaptureKit、AX、Carbon 热键，实现 Core 的协议。
        .target(name: "EVEOPreviewPlatform", dependencies: ["EVEOPreviewCore"]),
        // 应用本体：菜单栏、缩略图面板、设置窗口。
        .executableTarget(name: "EVEOPreview", dependencies: ["EVEOPreviewCore", "EVEOPreviewPlatform"]),
        // 命令行探针：在真实客户端上验证平台层，不进发布包。
        .executableTarget(name: "EVEOProbe", dependencies: ["EVEOPreviewCore", "EVEOPreviewPlatform"]),
        // Core 的 swift-testing 用例（本机没有 XCTest）。
        .testTarget(name: "EVEOPreviewCoreTests", dependencies: ["EVEOPreviewCore"]),
        // 临时：手写文案与 shared/l10n 生成的文案逐字对照（架构文档 5.2 节），切换完成后删除。
        .testTarget(name: "EVEOPreviewL10nTests", dependencies: ["EVEOPreview"]),
    ],
    // 全部目标使用 Swift 6 语言模式（严格并发检查）。
    swiftLanguageModes: [.v6]
)
