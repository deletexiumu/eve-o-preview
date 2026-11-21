// SPDX-License-Identifier: GPL-3.0-or-later
//
// 日文界面文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见协议里的注释（Strings.swift、SettingsStrings.swift）。
//
// 用词的依据：
// - 反馈文档 5.5 节的词表：サムネイル、クライアント、プロファイル、サイクルグループ、枠線、ハイライト 等。
// - EVE 日文客户端的叫法：角色是キャラクター，登录界面是ログイン画面。
// - macOS 日文的官方名称：「编辑」菜单各项取 AppKit 的 MenuCommands.loctable（ウインドウ的写法也随系统）；
//   权限名取系统设置（画面収録、アクセシビリティ），「系统设置 > 隐私与安全性」是
//   「システム設定」>「プライバシーとセキュリティ」，访达保留 Finder。
// - 「最小化」写最小化；macOS 菜单里的「しまう」指收进 Dock，用在 EVE 客户端上不够直白。
// - 文体用です・ます体；按钮与标签用名词或动词原形。

import Foundation
import EVEOPreviewCore

// MARK: - 菜单栏

/// 菜单栏菜单，日文。
struct MenuStringsJA: MenuStrings {
    var showAll: String { "すべてのサムネイルを表示" }
    var hideAll: String { "すべてのサムネイルを隠す" }
    var profiles: String { "プロファイル" }
    var minimizeAll: String { "すべてのクライアントを最小化" }
    var settings: String { "設定…" }
    var quit: String { "EVE-O Previewを終了" }
    var permissionsMissing: String { "権限が不足しています…" }
    var fakeMode: String { "デモモード（ダミークライアント）" }
    var noClients: String { "EVEクライアントが見つかりません" }
    func resumeCapture(_ title: String) -> String { "キャプチャを再開：\(title)" }
    // 日文没有复数变化。
    func clientCount(_ count: Int) -> String { "クライアント \(count) 個" }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，日文。全部取 macOS 日文的菜单名。
struct EditMenuStringsJA: EditMenuStrings {
    var title: String { "編集" }
    var undo: String { "取り消す" }
    var redo: String { "やり直す" }
    var cut: String { "カット" }
    var copy: String { "コピー" }
    var paste: String { "ペースト" }
    var selectAll: String { "すべてを選択" }
    var closeWindow: String { "ウインドウを閉じる" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，日文。
struct ThumbnailStringsJA: ThumbnailStrings {
    var minimize: String { "最小化" }
    var minimizeAll: String { "すべて最小化" }
    var skipCycle: String { "サイクルでスキップ" }
    var hide: String { "このサムネイルを隠す" }
    var resetSize: String { "デフォルトのサイズに戻す" }
    var resumeCapture: String { "キャプチャを再開" }
    var needsAccessibility: String { "アクセシビリティの権限が必要" }
    func unavailable(_ item: String, reason: String) -> String { "\(item)（\(reason)）" }
    var settings: String { "設定…" }
    // 占位文字。
    var waiting: String { "画面を待っています…" }
    var needsScreenRecording: String { "画面収録の権限が必要です" }
    var captureStopped: String { "キャプチャが停止しました。右クリックで再開できます。" }
    var minimized: String { "最小化中" }
}

// MARK: - 设置窗口

/// 设置窗口，日文。单位：pt（点）、秒、fps、ミリ秒。
struct SettingsStringsJA: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "EVE-O Preview 設定" }
    var points: String { "pt" }
    var reset: String { "リセット" }
    var defaultColor: String { "デフォルト" }
    var cancel: String { "キャンセル" }
    var confirm: String { "OK" }
    var delete: String { "削除" }
    var online: String { "オンライン" }
    var offline: String { "オフライン" }
    var forward: String { "進む" }
    var backward: String { "戻る" }
    func seconds(_ value: Double) -> String { String(format: "%.1f 秒", value) }
    func fps(_ value: Double) -> String { String(format: "%.0f fps", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f ミリ秒", value) }
    var fakeModeNotice: String {
        "デモモード：サムネイルはダミークライアントのものです。切り替えと最小化はデモ用のデータだけを変更します。"
    }
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "設定ファイルのバージョンは \(found) ですが、このビルドは \(supported) までしか対応していません。"
            + "デフォルト設定で動作しているため、変更は保存されません。"
    }
    func loadFailedNotice(_ message: String) -> String {
        "設定ファイルを読み込めませんでした（\(message)）。デフォルト設定で動作しているため、変更は保存されません。"
    }
    func quarantinedNotice(_ path: String) -> String {
        "設定ファイルが破損していたため、\(path) に移動しました。デフォルト設定を使用します。"
    }
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "\(path) の読み込みに失敗しました：\(reason)"
        case .write: return "\(path) の書き込みに失敗しました：\(reason)"
        case .quarantine: return "破損した設定ファイル \(path) の退避に失敗しました：\(reason)"
        case .backup: return "旧バージョンの設定を \(path) にバックアップできませんでした：\(reason)"
        }
    }
    var configContentInvalid: String { "ファイルの内容が有効な設定ではありません" }

    // 页名称。
    var pageClients: String { "クライアント" }
    var pagePreviews: String { "プレビューとレイアウト" }
    var pageSwitching: String { "切り替えとホットキー" }
    var pageAlerts: String { "アラート" }
    var pageProfiles: String { "プロファイル" }
    var pageGeneral: String { "一般" }
    var pagePermissions: String { "権限" }
    var pageAbout: String { "情報" }

    // 客户端页。
    var clientsSubtitle: String { "実行中のクライアントと、このプロファイルに記録されたキャラクター。" }
    var hideAllThumbnails: String { "すべてのサムネイルを隠す" }
    var hideAllHotkeyLabel: String { "ショートカット" }
    var hideAllScopeLabel: String { "有効範囲" }
    var hideAllHotkeyFooter: String {
        "修飾キーと通常のキー（例：⌃⌥⌘H）、または修飾キーとマウスの中ボタン・サイドボタンの組み合わせを使えます。上のすべてのショートカットに、ここで選んだ 1 つの範囲が適用されます。"
    }
    var charactersHeader: String { "キャラクター" }
    var charactersFooter: String { "このキャラクターがアクティブなときのハイライト枠線の色です。" }
    var noCharacters: String { "キャラクターはまだありません。EVEを起動してキャラクターでログインしてください。" }
    var loginClientsHeader: String { "ログイン画面のクライアント" }
    var showThumbnail: String { "サムネイルを表示" }
    var highlightColorHelp: String { "アクティブなときのハイライトの色" }

    // 预览与布局页。
    var previewsSubtitle: String { "サムネイルのサイズ、外観、動作。変更はすぐに反映されます。" }
    var defaultSize: String { "デフォルトのサイズ" }
    var minimumSize: String { "最小サイズ" }
    var maximumSize: String { "最大サイズ" }
    var unifySizes: String { "すべてのサムネイルをデフォルトのサイズに戻す" }
    var appearanceHeader: String { "外観" }
    var opacity: String { "不透明度" }
    var showTitle: String { "キャラクター名を表示" }
    var titleFontSize: String { "名前のフォントサイズ" }
    var titleColor: String { "名前の色" }
    var borderEnabled: String { "枠線を表示" }
    var borderColor: String { "枠線の色" }
    var borderThickness: String { "枠線の太さ" }
    var highlightEnabled: String { "アクティブなクライアントをハイライト" }
    var highlightColor: String { "ハイライトの色" }
    var highlightThickness: String { "ハイライトの太さ" }
    var zoomHeader: String { "ホバー時に拡大" }
    var zoomEnabled: String { "マウスを重ねると拡大" }
    var zoomFactor: String { "拡大率" }
    var zoomAnchor: String { "基準点" }
    var behaviorHeader: String { "動作" }
    var alwaysOnTop: String { "サムネイルを常に手前に表示" }
    var hideActiveClient: String { "アクティブなクライアントのサムネイルを隠す" }
    var hideWhenNotEVE: String { "EVEが前面にないときはサムネイルを隠す" }
    var hideDelay: String { "隠すまでの時間" }
    var layoutHeader: String { "レイアウト" }
    var snapEnabled: String { "ドラッグ時にスナップ" }
    var lockAspectRatio: String { "サイズ変更時に縦横比を保持" }
    var lockLayout: String { "レイアウトをロック" }
    var gestureHint: String {
        "右ドラッグまたはOption+ドラッグで移動、端をドラッグでサイズ変更。Shiftを押しながらドラッグするとスナップしません。"
    }
    var captureHeader: String { "キャプチャと位置" }
    var frameRate: String { "フレームレート" }
    var titleBarCrop: String { "タイトルバーの切り取り" }
    var pollInterval: String { "ウインドウの確認間隔" }
    var loginPositionX: String { "ログイン用サムネイルの X" }
    var loginPositionY: String { "ログイン用サムネイルの Y" }
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "左上"
        case .n: return "上"
        case .ne: return "右上"
        case .w: return "左"
        case .center: return "中央"
        case .e: return "右"
        case .sw: return "左下"
        case .s: return "下"
        case .se: return "右下"
        }
    }

    // 配置方案页。
    var profilesSubtitle: String { "プロファイルごとに、設定、レイアウト、サイクルグループを一式で持ちます。" }
    var activeBadge: String { "使用中" }
    var switchTo: String { "切り替え" }
    var rename: String { "名前を変更" }
    var clone: String { "複製" }
    var newProfile: String { "新規プロファイル" }
    var configFile: String { "設定ファイル" }
    var revealConfig: String { "Finderに表示" }
    var profileName: String { "プロファイル名" }
    var profileNameRule: String { "1〜64文字で、ほかのプロファイルと重ならない名前にしてください（大文字と小文字は区別しません）。" }
    func deleteProfileConfirm(_ name: String) -> String { "プロファイル「\(name)」を削除しますか？この操作は取り消せません。" }
    func cloneTitle(_ name: String) -> String { "「\(name)」を複製" }
    func renameTitle(_ name: String) -> String { "「\(name)」の名前を変更" }
    func copyName(_ name: String) -> String { "\(name) のコピー" }

    // 通用页。
    var generalSubtitle: String { "すべてのプロファイルに共通の設定。" }
    var interfaceLanguage: String { "表示言語" }
    var followSystem: String { "システムに合わせる" }
    var machineTranslationNote: String { "一部の翻訳は機械翻訳です。修正のご指摘を歓迎します。" }
    var showDockIcon: String { "Dock にアイコンを表示" }
    var showDockIconHelp: String { "オフにすると、メニューバーのアイコンだけが表示されます。" }

    // 权限页。
    var permissionsSubtitle: String { "どちらの権限も「システム設定」>「プライバシーとセキュリティ」で許可します。" }
    var screenRecording: String { "画面収録" }
    var screenRecordingDetail: String {
        "クライアントのウインドウのキャプチャとタイトルの読み取りに使います。通常、許可した後にこのアプリを再起動すると有効になります。"
    }
    var accessibility: String { "アクセシビリティ" }
    var accessibilityDetail: String {
        "クライアントのウインドウの復元、前面への移動、最小化と、マウスボタンのホットキーに使います。許可するとすぐに有効になります。"
    }
    var granted: String { "許可済み" }
    var notGranted: String { "未許可" }
    var request: String { "許可を求める" }
    var openSystemSettings: String { "システム設定を開く" }
    var relaunchHint: String { "画面収録を許可した後に再起動" }
    var relaunch: String { "再起動" }
    var signingHint: String {
        "macOSはコード署名ごとに権限を記録します。ad-hoc署名のビルドは、再ビルドのたびに許可し直す必要があります。"
            + "自己署名証明書を使う方法はREADMEを参照してください。"
    }

    // 关于页。
    var version: String { "バージョン" }
    var devVersion: String { "開発版" }
    var aboutSubtitle: String { "複数のEVE Onlineクライアントのライブサムネイルと素早い切り替え（macOSネイティブ版）。" }
    var aboutSummary: String {
        "クライアントごとにライブサムネイルを表示し、クリックで切り替えます。サイクルグループのホットキーと複数のプロファイルに対応しています。"
    }
    var upstreamHeader: String { "元のプロジェクトとライセンス" }
    var upstreamText: String { "このアプリは EveOPlus/eve-o-preview の機能をmacOS向けに新たに実装したものです。" }
    var licenseText: String { "元のプロジェクトと同じく、GNU General Public License v3.0（GPL-3.0）で公開しています。" }
    var disclaimerHeader: String { "注意事項" }
    var focusOnlyText: String {
        "このツールはウインドウのフォーカスを切り替えるだけです。複数のクライアントに同じ入力を送ることはなく、"
            + "ゲームのメモリを読み取ったり変更したりすることもありません。"
    }
    var gameLogText: String {
        "戦闘アラートは、EVEクライアントが書き出すゲームログのファイルを読むだけです。"
            + "ゲームのメモリは読まず、ファイルを変更せず、入力も送りません。"
    }
    var networkText: String {
        "EVE-O PreviewがGitHubに接続するのは、アップデートの確認とダウンロードのときだけです。「一般」でオフにできます。"
            + "問題のレポートが自動で送信されることはありません。"
    }
    var eveIPText: String {
        "EVE Onlineおよび関連するロゴはCCP ehf.の商標です。このプロジェクトはCCPとは関係がなく、CCPの承認も受けていません。"
    }
}

// MARK: - 预警与翻译（docs/design-intel-translate.md 第 11 节）
// 机器生成、待母语者审校的译文，用词按 11 节的词表：浮窗、预警、频道、聊天日志、模型服务。

/// 菜单栏的两个浮窗开关，日文。
extension MenuStringsJA {
    var showIntelOverlay: String { "偵察オーバーレイを表示" }
    var showTranslationOverlay: String { "翻訳オーバーレイを表示" }
}

/// 两个新页的页名、关于页的说明与聊天日志的状态，日文。
extension SettingsStringsJA {
    var pageIntel: String { "偵察" }
    var pageTranslation: String { "翻訳" }
    var aboutChatLogsNote: String {
        "偵察と翻訳はチャットログとゲームログを読み取るだけです。翻訳は、選択したモデルサービスにチャットの本文を送信します。「オンラインで名前を確認」がオンのときは、偵察メッセージ内で続けて書かれたパイロット名を CCP の ESI API に送信します。"
    }
    var chatLogStatusStopped: String { "オフ" }
    func chatLogStatusWatching(directory: String, files: Int) -> String {
        "監視中：\(directory)（ログファイル \(files) 件）"
    }
    func chatLogStatusDirectoryNotFound(_ path: String) -> String { "チャットログのフォルダが見つかりません：\(path)" }
    func chatLogStatusAccessDenied(_ path: String) -> String { "読み取り権限がありません：\(path)" }
    var chatLogHelp: String {
        "EVE クライアントでチャットをファイルに記録する設定を有効にしてください。ログのフォルダは「アラート」ページで設定します。"
    }
}
