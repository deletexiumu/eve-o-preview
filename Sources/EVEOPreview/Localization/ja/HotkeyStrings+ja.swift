// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键域的日文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：热键 ホットキー，循环组 サイクルグループ，缩略图 サムネイル，
// 客户端 クライアント，鼠标按键 マウスボタン，辅助功能 アクセシビリティ（macOS 日文版的官方名称）。

import Foundation

/// 热键域的日文实现。
struct HotkeyStringsJA: HotkeyStrings {
    // MARK: 切换与热键页：页首与循环组

    var switchingSubtitle: String { "サイクルグループとホットキー。各ホットキーはどこでも、または EVE 内だけで使えます。" }
    var cycleGroupsHeader: String { "サイクルグループ" }
    var addGroup: String { "新規サイクルグループ" }
    var noGroups: String { "サイクルグループはまだありません。" }
    var groupName: String { "名前" }
    var deleteGroup: String { "グループを削除" }
    var forwardHotkeys: String { "進むホットキー" }
    var backwardHotkeys: String { "戻るホットキー" }
    var noMembers: String { "メンバーはまだいません。" }
    var addMember: String { "メンバーを追加" }
    func newGroupName(_ index: Int) -> String { "グループ \(index)" }

    // MARK: 切换与热键页：角色热键与通用热键

    var characterHotkeysHeader: String { "キャラクターのホットキー" }
    var globalHotkeysHeader: String { "共通ホットキー" }
    var hotkeyToggleHideAll: String { "すべてのサムネイルを表示／非表示" }
    var hotkeyMinimizeAll: String { "すべてのクライアントを最小化" }
    var hotkeyCycleLogin: String { "ログイン画面のクライアントを順に切り替え" }
    var hotkeyRulesHint: String {
        "キーボードのホットキーには Control、Option、Command のいずれかが必要です（F1〜F20 とテンキーの数字は単独で可）。"
            + "マウスの中ボタンとサイドボタンは単独で使え、押してもクリックはゲームに渡りません。"
    }
    var mouseHotkeyHint: String {
        "マウスのホットキーにはアクセシビリティの許可が必要です。範囲が「グローバル」のマウスボタンは"
            + "すべてのアプリで横取りされます。先にゲームやマウスのソフトウェアでこのボタンの割り当てを解除してください。"
    }

    // MARK: 作用范围

    var defaultScopeLabel: String { "ホットキーの既定の範囲" }
    var scopeGlobal: String { "グローバル" }
    var scopeGame: String { "EVE 内のみ" }
    func scopeFollowDefault(_ current: String) -> String { "既定に従う（現在：\(current)）" }
    func scopeMenuHelp(_ resolved: String) -> String { "範囲：\(resolved)" }
    var menuHotkeysOnlyInEVE: String { "ホットキーを EVE 内のみで有効にする" }

    // MARK: 录制器

    var addHotkey: String { "+ 追加" }
    var recordingPrompt: String { "キーかマウスのサイドボタンを押す（ポインタはこのウインドウ内）…" }
    var recorderHelp: String {
        "クリックしてから、キーの組み合わせかマウスの中ボタン・サイドボタンを押します。Esc で取消、Delete で消去。"
    }
    var removeHotkey: String { "このホットキーを削除" }

    // MARK: 热键问题

    var hotkeyUnparsable: String { "認識できません" }
    var hotkeyMissingModifier: String { "修飾キーが必要" }
    var hotkeyReserved: String { "macOS が使用中" }
    var hotkeyAccessibilityRequired: String { "アクセシビリティが必要" }
    var hotkeyEventTapUnavailable: String { "マウスを監視できません" }
    func hotkeyDuplicate(_ other: String) -> String { "「\(other)」と重複" }
    func hotkeyRegistrationFailed(_ status: Int32) -> String { "登録に失敗（\(status)）" }
}
