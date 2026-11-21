// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的中文文字。成员顺序与协议一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表（更新、检查更新…、发布说明、安装更新、跳过此版本、稍后、签名）
// 与第 18 节的术语（测试地址、只提示）；不能自动安装的原因取 9.1 节「窗口里的说明」一栏。
// 状态文字写成「检查中…」「下载中…」，不用「正在」。

import Foundation

/// 更新域的中文实现。
struct UpdateStringsZH: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "检查更新…" }
    func menuUpdateAvailable(_ version: String) -> String { "有可用更新：\(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "重新启动以更新到 \(version)" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "更新" }
    var autoCheckToggle: String { "自动检查更新" }
    var autoCheckHelp: String { "每天访问一次 GitHub，不发送个人数据。" }
    var autoInstallToggle: String { "自动安装更新" }
    var autoInstallHelp: String { "在后台下载。没有 EVE 客户端运行满 1 分钟时安装并重新启动；也会在退出 EVE-O Preview 时安装。" }
    var currentVersionLabel: String { "当前版本" }
    var lastCheckedLabel: String { "上次检查" }
    var lastCheckedNever: String { "从未检查" }
    var checkNowButton: String { "立即检查" }

    // MARK: 状态行

    var statusChecking: String { "检查中…" }
    var statusUpToDate: String { "EVE-O Preview 已是最新版本。" }
    func statusAvailable(_ version: String) -> String { "新版本 \(version) 可用。" }
    func statusReady(_ version: String) -> String { "新版本 \(version) 已下载，将在没有 EVE 客户端运行时或退出时安装。" }
    func statusRateLimited(_ time: String) -> String { "GitHub 限制了请求次数，请在 \(time) 之后再试。" }
    var statusRateLimitedLater: String { "GitHub 限制了请求次数，请稍后再试。" }
    var statusUnavailable: String { "这个构建不能使用更新功能。" }

    // MARK: 更新窗口

    var windowTitle: String { "软件更新" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) 可用" }
    func currentVersionLine(_ version: String) -> String { "当前版本是 \(version)。" }
    var releaseNotesHeader: String { "新内容" }
    func versionNotesTitle(_ version: String) -> String { "版本 \(version)" }
    var earlierVersionsOnReleasePage: String { "更早版本的更新内容请到发布页查看。" }
    var installButton: String { "安装更新" }
    var installHelp: String { "安装后应用会重新启动，缩略图会消失几秒。" }
    var skipButton: String { "跳过此版本" }
    var laterButton: String { "稍后" }
    var openReleasePageButton: String { "打开发布页" }
    var cancelButton: String { "取消" }
    var closeButton: String { "关闭" }
    var retryButton: String { "重试" }
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "下载中… \(received)，共 \($0)" } ?? "下载中… \(received)"
    }
    var progressVerifying: String { "核对中…" }
    var progressInstalling: String { "安装中…" }
    var progressRelaunching: String { "重新启动中…" }
    var testFeedBadge: String { "测试地址" }
    var notifyOnlyIntro: String { "这份应用不能自己更新。" }
    var currentVersionUnchanged: String { "当前版本没有变化。" }
    var reopenManually: String { "更新已安装。请退出并重新打开 EVE-O Preview。" }

    // MARK: 不能自动安装的原因

    var blockerTranslocated: String { "系统在临时的只读位置运行这个应用。请把应用移到「应用程序」文件夹后重新打开。" }
    var blockerUnsupportedVolume: String { "应用所在的磁盘不是 APFS 格式，不能在应用内安装更新。请从发布页下载新版本。" }
    var blockerReadOnlyVolume: String { "应用在只读的磁盘上。请先拷贝到「应用程序」文件夹。" }
    var blockerLocationNotWritable: String { "当前用户没有权限改动应用所在的文件夹。" }
    var blockerAdHocSignature: String { "这个构建没有稳定的签名，无法核对新版本。" }
    var blockerDevelopmentSignature: String { "这是本机签名的开发构建。" }
    var blockerUnsigned: String { "这个构建没有签名。" }

    // MARK: 错误

    var errorNetwork: String { "无法连接 GitHub。请检查网络连接。" }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub 返回了错误（\(code)）。" }
    var errorMalformedFeed: String { "无法读取发布信息。" }
    var errorAssetMissing: String { "这个版本没有供自动更新使用的安装包。" }
    var errorDiskSpace: String { "磁盘空间不足，无法下载。" }
    var errorChecksum: String { "下载的文件与校验和不符，已丢弃。" }
    var errorDiskImage: String { "无法打开下载的磁盘映像。" }
    var errorVerification: String { "无法验证新版本，没有安装。" }
    func errorUnsupportedSystem(_ minimum: String) -> String { "这个版本需要 macOS \(minimum) 或更高版本。" }
    var errorSwapFailed: String { "无法替换应用。" }
}
