// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的日文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与菜单栏一致：オーバーレイ、チャンネル、「レイアウトをロック」。

import Foundation

/// 浮窗与两页共用设置控件的日文文字。
struct OverlayStringsJA: OverlayStrings {
    // MARK: 浮窗的列表
    func newMessages(_ count: Int) -> String { "新着 \(count) 件" }
    var noActiveCharacter: String { "現在のウィンドウにキャラクターがいません" }
    var emptyList: String { "まだメッセージはありません" }

    // MARK: 浮窗的右键菜单
    var menuScrollToLatest: String { "最新までスクロール" }
    var menuCopyLine: String { "この行をコピー" }
    var menuOpenInBrowser: String { "ブラウザで開く" }
    var menuClear: String { "リストを消去" }
    var menuLockLayout: String { "レイアウトをロック" }
    var menuResetFrame: String { "位置とサイズをデフォルトに戻す" }
    var menuHide: String { "このオーバーレイを隠す" }
    var menuOpenSettings: String { "設定を開く…" }

    // MARK: 浮窗设置
    var overlayHeader: String { "オーバーレイ" }
    var opacity: String { "背景の不透明度" }
    var fontSize: String { "文字サイズ" }
    var resetFrame: String { "位置をデフォルトに戻す" }
    var gestureHelp: String { "右ドラッグまたは Option を押しながら左ドラッグで移動、端にポインタを合わせて左ドラッグでサイズ変更、スクロールでリストを送ります。" }
    var positionLabel: String { "位置" }
    var sizeLabel: String { "サイズ" }
    var frameHelp: String { "位置はメインディスプレイの左上を原点とするポイント単位です。サイズは 220×120〜900×900 に制限され、画面外の位置は画面内に戻されます。" }

    // MARK: 频道列表
    var channelsHeader: String { "チャンネル" }
    var addFromLogs: String { "ログから追加" }
    var addByNamePlaceholder: String { "チャンネル名を入力して Return キーを押す" }
    var removeChannel: String { "削除" }
    var noChannels: String { "チャンネルはまだありません" }
    var refreshChannels: String { "更新" }
    var noDiscoveredChannels: String { "最近のチャットログが見つかりません" }
    func channelListeners(_ count: Int) -> String { "\(count) キャラクター" }

    // MARK: 内置频道
    var builtInLocal: String { "ローカル" }
    var builtInCorp: String { "コーポレーション" }
    var builtInAlliance: String { "アライアンス" }
    var builtInFleet: String { "フリート" }
}
