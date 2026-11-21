// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的界面文字（v1.1 设计 11.4 节）：菜单栏的「检查更新…」与提示项、「通用」页的更新一组、更新窗口。
// 每种语言在 Localization/<语言>/UpdateStrings+<语言>.swift 里各有一个结构体实现本协议；
// 漏了一条时结构体不满足协议，编译不过。带参数的文字写成函数，各语言自己拼接，不用格式串。
// 用词按 v1.1 设计 11.3 节与反馈文档 5.5 节的词表。
//
// 11.4 节的 `blocker(_:)` 与 `error(_:)` 写在本文件的协议扩展里：各语言只写每种原因与每类错误的一句话，
// 从 `InstallBlocker`、`UpdateError` 到句子的对应只在这里写一次。
// 文件大小与时刻按界面语言对应的 `Locale` 格式化（`UpdateTextFormat`），不另设文字键。

import Foundation
import EVEOPreviewCore

/// 更新域的全部文字。
protocol UpdateStrings: Sendable {
    // MARK: 菜单栏菜单

    /// 工具项「检查更新…」。
    var menuCheckForUpdates: String { get }
    /// 顶部的提示项：有可用更新，参数是新版本号。
    func menuUpdateAvailable(_ version: String) -> String
    /// 顶部的提示项：新版本已下载好，点击后安装并重新启动；参数是新版本号。更新窗口的同名按钮也用它。
    func menuRestartToUpdate(_ version: String) -> String

    // MARK: 「通用」页的更新一组

    /// 一组的标题。
    var sectionHeader: String { get }
    /// 「自动检查更新」开关。
    var autoCheckToggle: String { get }
    /// 「自动检查更新」的说明。
    var autoCheckHelp: String { get }
    /// 「自动安装更新」开关。
    var autoInstallToggle: String { get }
    /// 「自动安装更新」的说明。
    var autoInstallHelp: String { get }
    /// 「当前版本」一行的标签。
    var currentVersionLabel: String { get }
    /// 「上次检查」一行的标签。
    var lastCheckedLabel: String { get }
    /// 从来没有检查过。
    var lastCheckedNever: String { get }
    /// 「立即检查」按钮；更新窗口在空闲时也用它。
    var checkNowButton: String { get }

    // MARK: 状态行（「通用」页与更新窗口）

    /// 检查中。
    var statusChecking: String { get }
    /// 已是最新版本。
    var statusUpToDate: String { get }
    /// 有新版本，参数是版本号。
    func statusAvailable(_ version: String) -> String
    /// 新版本已下载，退出时安装；参数是版本号。
    func statusReady(_ version: String) -> String
    /// GitHub 限流，参数是可以再试的时刻（已按界面语言格式化）。
    func statusRateLimited(_ time: String) -> String
    /// GitHub 限流，可以再试的时刻未知。
    var statusRateLimitedLater: String { get }
    /// 这个构建整个停用更新功能（不是从 .app 运行）。
    var statusUnavailable: String { get }

    // MARK: 更新窗口

    /// 窗口标题。
    var windowTitle: String { get }
    /// 标题行，参数是新版本号。
    func headline(_ version: String) -> String
    /// 标题下一行，参数是正在运行的版本。
    func currentVersionLine(_ version: String) -> String
    /// 发布说明上方的小标题。
    var releaseNotesHeader: String { get }
    /// 跳过了几个版本时，每个版本的说明前的小标题，参数是版本号（8.8 节）。
    func versionNotesTitle(_ version: String) -> String
    /// 中间版本没有列全时，说明最后的一行：更早版本的内容请看发布页。
    var earlierVersionsOnReleasePage: String { get }
    /// 「安装更新」按钮。
    var installButton: String { get }
    /// 「安装更新」下方的说明。
    var installHelp: String { get }
    /// 「跳过此版本」按钮。
    var skipButton: String { get }
    /// 「稍后」按钮。
    var laterButton: String { get }
    /// 「打开发布页」按钮。
    var openReleasePageButton: String { get }
    /// 「取消」按钮。
    var cancelButton: String { get }
    /// 「关闭」按钮。
    var closeButton: String { get }
    /// 「重试」按钮。
    var retryButton: String { get }
    /// 下载进度；两个参数是已格式化的大小，total 为 nil 表示总大小未知。
    func progressDownloading(received: String, total: String?) -> String
    /// 核对中。
    var progressVerifying: String { get }
    /// 安装中。
    var progressInstalling: String { get }
    /// 重新启动中。
    var progressRelaunching: String { get }
    /// 使用测试地址时标题旁的字样。
    var testFeedBadge: String { get }
    /// 只提示时，原因前面的一句。
    var notifyOnlyIntro: String { get }
    /// 失败时：当前版本没有变化。
    var currentVersionUnchanged: String { get }
    /// 安装成功但重新启动失败时的说明。
    var reopenManually: String { get }

    // MARK: 不能自动安装的原因（InstallBlocker）

    /// `translocated`。
    var blockerTranslocated: String { get }
    /// `readOnlyVolume`。
    var blockerReadOnlyVolume: String { get }
    /// `locationNotWritable`。
    var blockerLocationNotWritable: String { get }
    /// `unsupportedVolume`。
    var blockerUnsupportedVolume: String { get }
    /// `adHocSignature`。
    var blockerAdHocSignature: String { get }
    /// `developmentSignature`。
    var blockerDevelopmentSignature: String { get }
    /// `unsigned`。
    var blockerUnsigned: String { get }

    // MARK: 错误（UpdateError，按类合并）

    /// `network`。
    var errorNetwork: String { get }
    /// `httpStatus`，参数是状态码。
    func errorHTTPStatus(_ code: Int) -> String
    /// `malformedFeed`。
    var errorMalformedFeed: String { get }
    /// `assetMissing`。
    var errorAssetMissing: String { get }
    /// `insufficientDiskSpace`、`downloadTooLarge`。
    var errorDiskSpace: String { get }
    /// `checksumListInvalid`、`checksumEntryMissing`、`checksumMismatch`。
    var errorChecksum: String { get }
    /// `imageMountFailed`、`appMissingInImage`。
    var errorDiskImage: String { get }
    /// `signatureInvalid`、`requirementNotSatisfied`、`bundleMismatch`、`versionMismatch`、`notNewer`。
    var errorVerification: String { get }
    /// `unsupportedSystem`，参数是要求的最低系统版本。
    func errorUnsupportedSystem(_ minimum: String) -> String
    /// `swapFailed`。
    var errorSwapFailed: String { get }
}

extension UpdateStrings {
    /// 不能自动安装的原因（11.4 节的 `blocker(blocker)`）。
    func blocker(_ blocker: InstallBlocker) -> String {
        switch blocker {
        case .translocated: return blockerTranslocated
        case .readOnlyVolume: return blockerReadOnlyVolume
        case .locationNotWritable: return blockerLocationNotWritable
        case .unsupportedVolume: return blockerUnsupportedVolume
        case .adHocSignature: return blockerAdHocSignature
        case .developmentSignature: return blockerDevelopmentSignature
        case .unsigned: return blockerUnsigned
        }
    }

    /// 错误的说明（11.4 节的 `error(error)`）。`cancelled` 不显示，返回 nil。
    /// 限流用 `statusRateLimited`，时刻未知时用 `statusRateLimitedLater`；`blocked` 用 `blocker(_:)`。
    func error(_ error: UpdateError) -> String? {
        switch error {
        case .network: return errorNetwork
        case .httpStatus(let code): return errorHTTPStatus(code)
        case .rateLimited(let until):
            return until.map { statusRateLimited(UpdateTextFormat.retryTime($0)) } ?? statusRateLimitedLater
        case .malformedFeed: return errorMalformedFeed
        case .assetMissing: return errorAssetMissing
        case .insufficientDiskSpace, .downloadTooLarge: return errorDiskSpace
        case .checksumListInvalid, .checksumEntryMissing, .checksumMismatch: return errorChecksum
        case .imageMountFailed, .appMissingInImage: return errorDiskImage
        case .signatureInvalid, .requirementNotSatisfied, .bundleMismatch, .versionMismatch, .notNewer:
            return errorVerification
        case .unsupportedSystem(let minimum): return errorUnsupportedSystem(minimum)
        case .blocked(let reason): return blocker(reason)
        case .swapFailed: return errorSwapFailed
        case .cancelled: return nil
        }
    }
}

extension L10n {
    /// 更新域的文字，按当前界面语言取。每次访问都重新取，切换语言后下次访问即是新语言。
    ///
    /// `switch` 不写 `default`：以后加语言时编译器会指出这里要补。
    static var updates: any UpdateStrings {
        switch L10n.language {
        case .en: return UpdateStringsEN()
        case .zh: return UpdateStringsZH()
        case .ru: return UpdateStringsRU()
        case .ja: return UpdateStringsJA()
        case .ko: return UpdateStringsKO()
        case .fr: return UpdateStringsFR()
        case .de: return UpdateStringsDE()
        case .es: return UpdateStringsES()
        }
    }
}

/// 更新界面里的大小与时刻的格式化，跟随界面语言（不是系统语言）对应的 `Locale`（11.4 节末尾）。
///
/// 文件大小用 `ByteCountFormatStyle`：设计写的 `ByteCountFormatter` 不能指定 `Locale`，只跟随系统语言。
enum UpdateTextFormat {
    /// 界面语言对应的 `Locale`。中文取简体。
    static var locale: Locale {
        switch L10n.language {
        case .en: return Locale(identifier: "en")
        case .zh: return Locale(identifier: "zh-Hans")
        case .ru: return Locale(identifier: "ru")
        case .ja: return Locale(identifier: "ja")
        case .ko: return Locale(identifier: "ko")
        case .fr: return Locale(identifier: "fr")
        case .de: return Locale(identifier: "de")
        case .es: return Locale(identifier: "es")
        }
    }

    /// 文件大小，如 `1.2 MB`。
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatStyle(style: .file, locale: locale).format(count)
    }

    /// 日期与时刻，「通用」页的「上次检查」用。
    static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    /// 限流后可以再试的时刻：今天之内只写时刻（如 `14:05`），否则带上日期。
    static func retryTime(_ date: Date, now: Date = Date()) -> String {
        let sameDay = Calendar.current.isDate(date, inSameDayAs: now)
        return date.formatted(Date.FormatStyle(date: sameDay ? .omitted : .abbreviated, time: .shortened, locale: locale))
    }
}
