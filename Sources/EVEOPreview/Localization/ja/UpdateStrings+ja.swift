// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的日文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与协议一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表：アップデート、アップデートを確認…（macOS 日文版的说法）、リリースノート、
// アップデートをインストール、このバージョンをスキップ、あとで、署名；缩略图 サムネイル（反馈文档 5.5 节）。
// 「应用程序」文件夹写「アプリケーション」（macOS 日文版的名称），说明句用です・ます体。

import Foundation

/// 更新域的日文实现。
struct UpdateStringsJA: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "アップデートを確認…" }
    func menuUpdateAvailable(_ version: String) -> String { "利用可能なアップデート：\(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "再起動して \(version) にアップデート" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "アップデート" }
    var autoCheckToggle: String { "アップデートを自動的に確認" }
    var autoCheckHelp: String { "1 日に 1 回 GitHub に接続します。個人データは送信されません。" }
    var autoInstallToggle: String { "アップデートを自動的にインストール" }
    var autoInstallHelp: String { "バックグラウンドでダウンロードします。EVE クライアントが 1 分間起動していなければインストールして再起動し、EVE-O Preview の終了時にもインストールします。" }
    var currentVersionLabel: String { "現在のバージョン" }
    var lastCheckedLabel: String { "最終確認" }
    var lastCheckedNever: String { "未確認" }
    var checkNowButton: String { "今すぐ確認" }

    // MARK: 状态行

    var statusChecking: String { "確認中…" }
    var statusUpToDate: String { "EVE-O Preview は最新です。" }
    func statusAvailable(_ version: String) -> String { "バージョン \(version) が利用可能です。" }
    func statusReady(_ version: String) -> String {
        "バージョン \(version) はダウンロード済みです。終了時にインストールされます。"
    }
    func statusRateLimited(_ time: String) -> String {
        "GitHub がリクエストを制限しています。\(time) 以降にもう一度お試しください。"
    }
    var statusRateLimitedLater: String { "GitHub がリクエストを制限しています。しばらくしてからもう一度お試しください。" }
    var statusUnavailable: String { "このビルドではアップデートを利用できません。" }

    // MARK: 更新窗口

    var windowTitle: String { "ソフトウェアアップデート" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) が利用可能です" }
    func currentVersionLine(_ version: String) -> String { "現在のバージョンは \(version) です。" }
    var releaseNotesHeader: String { "新機能" }
    var installButton: String { "アップデートをインストール" }
    var installHelp: String { "インストール後にアプリが再起動します。サムネイルが数秒間消えます。" }
    var skipButton: String { "このバージョンをスキップ" }
    var laterButton: String { "あとで" }
    var openReleasePageButton: String { "リリースページを開く" }
    var cancelButton: String { "キャンセル" }
    var closeButton: String { "閉じる" }
    var retryButton: String { "再試行" }
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "ダウンロード中… \(received) / \($0)" } ?? "ダウンロード中… \(received)"
    }
    var progressVerifying: String { "検証中…" }
    var progressInstalling: String { "インストール中…" }
    var progressRelaunching: String { "再起動中…" }
    var testFeedBadge: String { "テスト用アドレス" }
    var notifyOnlyIntro: String { "このコピーは自動でアップデートできません。" }
    var currentVersionUnchanged: String { "現在のバージョンは変更されていません。" }
    var reopenManually: String { "アップデートはインストールされました。EVE-O Preview を終了して、もう一度開いてください。" }

    // MARK: 不能自动安装的原因

    var blockerTranslocated: String {
        "macOS がアプリを一時的な読み取り専用の場所から実行しています。"
            + "アプリを「アプリケーション」フォルダに移動してから、もう一度開いてください。"
    }
    var blockerReadOnlyVolume: String {
        "アプリは読み取り専用のディスク上にあります。先に「アプリケーション」フォルダにコピーしてください。"
    }
    var blockerLocationNotWritable: String { "アプリが入っているフォルダを変更する権限がありません。" }
    var blockerAdHocSignature: String { "このビルドには固定の署名がないため、新しいバージョンを検証できません。" }
    var blockerDevelopmentSignature: String { "これはローカルで署名された開発用ビルドです。" }
    var blockerUnsigned: String { "このビルドは署名されていません。" }

    // MARK: 错误

    var errorNetwork: String { "GitHub に接続できませんでした。インターネット接続を確認してください。" }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub がエラーを返しました（\(code)）。" }
    var errorMalformedFeed: String { "リリース情報を読み取れませんでした。" }
    var errorAssetMissing: String { "このリリースには自動アップデート用のインストーラがありません。" }
    var errorDiskSpace: String { "ダウンロードに必要なディスクの空き容量が足りません。" }
    var errorChecksum: String { "ダウンロードしたファイルがチェックサムと一致しないため、破棄しました。" }
    var errorDiskImage: String { "ダウンロードしたディスクイメージを開けませんでした。" }
    var errorVerification: String { "新しいバージョンを検証できなかったため、インストールしませんでした。" }
    func errorUnsupportedSystem(_ minimum: String) -> String { "このバージョンには macOS \(minimum) 以降が必要です。" }
    var errorSwapFailed: String { "アプリを置き換えられませんでした。" }
}
