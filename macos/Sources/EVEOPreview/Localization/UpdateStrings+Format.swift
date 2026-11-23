// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域文字的补充（v1.1 设计 11.4 节），各语言共用：
// - 11.4 节的 `blocker(_:)` 与 `error(_:)`：各语言只写每种原因与每类错误的一句话，
//   从 `InstallBlocker`、`UpdateError` 到句子的对应只在这里写一次。
// - 文件大小与时刻按界面语言对应的 `Locale` 格式化（`UpdateTextFormat`），不另设文字键。
// 协议与各语言的文字由 shared/l10n 生成（Generated/UpdateStrings.swift）。

import Foundation
import EVEOPreviewCore

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
