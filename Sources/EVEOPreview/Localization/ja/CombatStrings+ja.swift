// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的日文文字（反馈文档 5.3 节、7.11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：戦闘アラート、ゲームログ、サムネイル、枠線；系统权限用 macOS 日文界面的
// 「ファイルとフォルダ」。

import Foundation

/// 「提醒」页的日文文字。
struct CombatStringsJA: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "キャラクターが攻撃されたとき、そのサムネイルを点滅させます。" }

    // MARK: 开关与状态行
    var enableToggle: String { "キャラクターが攻撃されたらサムネイルを点滅" }
    var statusLabel: String { "状態" }
    var statusStopped: String { "オフ" }
    func statusWatching(directory: String, files: Int) -> String {
        "監視中：\(directory)（ログファイル \(files) 件）"
    }
    func statusDirectoryNotFound(_ path: String) -> String { "ゲームログのフォルダが見つかりません：\(path)" }
    func statusAccessDenied(_ path: String) -> String { "読み取り権限がありません：\(path)" }
    var accessDeniedHelp: String {
        "「システム設定 > プライバシーとセキュリティ > ファイルとフォルダ」で、"
            + "EVE-O Preview に「書類」フォルダへのアクセスを許可してください。"
    }
    var openSystemSettings: String { "システム設定を開く…" }

    // MARK: 日志目录
    var logDirectoryHeader: String { "ゲームログ" }
    var logDirectoryLabel: String { "フォルダ" }
    var automaticSuffix: String { "（自動）" }
    var chooseDirectory: String { "選択…" }
    var useAutomaticLocation: String { "自動検出を使用" }
    var chooseDirectoryMessage: String { "EVE の「logs」または「Gamelogs」フォルダを選択してください。" }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "点滅" }
    var flashColor: String { "点滅の色" }
    var duration: String { "持続時間" }
    func seconds(_ value: Double) -> String { "\(combatSecondsNumber(value)) 秒" }
    var style: String { "スタイル" }
    var styleBorder: String { "枠線" }
    var styleWash: String { "塗り" }
    var styleBoth: String { "両方" }

    // MARK: 触发条件
    var triggersHeader: String { "条件" }
    var includeMisses: String { "外れた攻撃でも通知する" }
    var minimumDamage: String { "最小ダメージ" }
    var minimumDamageHelp: String { "この値未満のダメージでは通知しません。外れた攻撃は上のスイッチに従います。" }

    // MARK: 测试与说明
    var testFlash: String { "点滅をテスト" }
    var testFlashHelp: String { "機能がオフでも、すべてのサムネイルを一度点滅させます。" }
    var footnote: String {
        "EVE クライアントでゲームメッセージをログファイルに書き出す設定を有効にしてください。"
            + "この機能はゲームログを読むだけで、ゲームに入力を送ることはありません。"
    }
}
