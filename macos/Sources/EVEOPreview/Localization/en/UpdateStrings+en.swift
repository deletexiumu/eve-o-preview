// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的英文文字（v1.1 设计 11.4 节的原文）。成员顺序与协议一致，每条的用途见 UpdateStrings.swift。

import Foundation

/// 更新域的英文实现。
struct UpdateStringsEN: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "Check for Updates…" }
    func menuUpdateAvailable(_ version: String) -> String { "Update Available: \(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "Restart to Update to \(version)" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "Updates" }
    var autoCheckToggle: String { "Check for updates automatically" }
    var autoCheckHelp: String { "Contacts GitHub once a day. No personal data is sent." }
    var autoInstallToggle: String { "Install updates automatically" }
    var autoInstallHelp: String { "Downloads in the background. Installs and restarts when no EVE client has been running for a minute, or installs when you quit EVE-O Preview." }
    var currentVersionLabel: String { "Current version" }
    var lastCheckedLabel: String { "Last checked" }
    var lastCheckedNever: String { "Never" }
    var checkNowButton: String { "Check Now" }

    // MARK: 状态行

    var statusChecking: String { "Checking…" }
    var statusUpToDate: String { "EVE-O Preview is up to date." }
    func statusAvailable(_ version: String) -> String { "Version \(version) is available." }
    func statusReady(_ version: String) -> String {
        "Version \(version) is downloaded. It will be installed when no EVE client is running, or when you quit."
    }
    func statusRateLimited(_ time: String) -> String { "GitHub is limiting requests. Try again after \(time)." }
    var statusRateLimitedLater: String { "GitHub is limiting requests. Try again later." }
    var statusUnavailable: String { "Updates are not available in this build." }

    // MARK: 更新窗口

    var windowTitle: String { "Software Update" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) is available" }
    func currentVersionLine(_ version: String) -> String { "You have \(version)." }
    var releaseNotesHeader: String { "What's New" }
    func versionNotesTitle(_ version: String) -> String { "Version \(version)" }
    var earlierVersionsOnReleasePage: String { "Changes in earlier versions are on the release page." }
    var installButton: String { "Install Update" }
    var installHelp: String { "The app restarts after installing. Thumbnails disappear for a few seconds." }
    var skipButton: String { "Skip This Version" }
    var laterButton: String { "Later" }
    var openReleasePageButton: String { "Open Release Page" }
    var cancelButton: String { "Cancel" }
    var closeButton: String { "Close" }
    var retryButton: String { "Try Again" }
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "Downloading… \(received) of \($0)" } ?? "Downloading… \(received)"
    }
    var progressVerifying: String { "Verifying…" }
    var progressInstalling: String { "Installing…" }
    var progressRelaunching: String { "Restarting…" }
    var testFeedBadge: String { "Test feed" }
    var notifyOnlyIntro: String { "This copy can't update itself." }
    var currentVersionUnchanged: String { "Your current version is unchanged." }
    var reopenManually: String { "The update is installed. Quit and open EVE-O Preview again." }

    // MARK: 不能自动安装的原因

    var blockerTranslocated: String {
        "macOS is running the app from a temporary read-only location. Move it to the Applications folder, then open it again."
    }
    var blockerUnsupportedVolume: String { "The app is on a disk that is not formatted as APFS, so updates cannot be installed in the app. Download the new version from the release page." }
    var blockerReadOnlyVolume: String { "The app is on a read-only disk. Copy it to the Applications folder first." }
    var blockerLocationNotWritable: String { "You don't have permission to change the folder that contains the app." }
    var blockerAdHocSignature: String {
        "This build has no stable signature, so a new version can't be verified against it."
    }
    var blockerDevelopmentSignature: String { "This is a locally signed development build." }
    var blockerUnsigned: String { "This build isn't signed." }

    // MARK: 错误

    var errorNetwork: String { "Couldn't reach GitHub. Check your internet connection." }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub answered with an error (\(code))." }
    var errorMalformedFeed: String { "The release information couldn't be read." }
    var errorAssetMissing: String { "This release has no installer for automatic updates." }
    var errorDiskSpace: String { "There isn't enough free disk space for the download." }
    var errorChecksum: String { "The download doesn't match its checksum and was discarded." }
    var errorDiskImage: String { "The downloaded disk image couldn't be opened." }
    var errorVerification: String { "The new version couldn't be verified, so it wasn't installed." }
    func errorUnsupportedSystem(_ minimum: String) -> String { "This version requires macOS \(minimum) or later." }
    var errorSwapFailed: String { "The app couldn't be replaced." }
}
