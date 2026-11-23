// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警域的日文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与 WP-0 的日文文字一致：偵察（预警）、オーバーレイ（浮窗）、チャンネル（频道）、チャットログ（聊天日志）；
// 跳是ジャンプ，敌对是敵対，星图数据是マップデータ，ESI 不翻译。
// 开关名「オンラインで名前を確認」与 settings.aboutChatLogsNote 里引用的写法逐字相同，后面加（ESI）。

import Foundation

/// 预警域的日文文字。
struct IntelStringsJA: IntelStrings {
    // MARK: 页头、开关与频道
    var pageSubtitle: String { "偵察チャンネルのチャットログを読み、敵対者の位置、人数、艦船、距離を表示します。" }
    var enableToggle: String { "偵察オーバーレイを表示" }
    var statusLabel: String { "状態" }
    var channelsHelp: String { "敵情が報告されるチャンネルを選択してください。" }

    // MARK: 我的位置
    var locationHeader: String { "現在地" }
    var locationHelp: String {
        "現在地はゲームログのジャンプ記録とローカルチャンネルのログから取得します。どちらもないときはここに入力してください。"
    }
    var locationUnknown: String { "不明" }
    func locationValue(system: String, source: String, age: String) -> String { "\(system)（\(source)、\(age)前）" }
    var sourceGameLog: String { "ゲームログ" }
    var sourceLocal: String { "ローカルチャンネル" }
    var sourceManual: String { "手動" }
    var systemPlaceholder: String { "星系名を入力して Return キー" }
    var clearLocation: String { "クリア" }
    var systemNotFound: String { "この星系が見つかりません" }
    var noOnlineCharacters: String { "オンラインのキャラクターがいません" }
    var referenceSystem: String { "基準星系" }
    var referenceSystemHelp: String { "キャラクターの現在地が不明なとき、ジャンプ数は基準星系から数えます。" }

    // MARK: 显示
    var displayHeader: String { "表示" }
    var windowMinutes: String { "保持する期間" }
    func minutes(_ count: Int) -> String { "\(count) 分" }
    var maxJumps: String { "計算の上限" }
    func jumpsUnit(_ count: Int) -> String { "\(count) ジャンプ" }
    var alertJumps: String { "ハイライトの範囲" }
    var alertJumpsHelp: String { "このジャンプ数以内の報告をハイライトします。0 にするとハイライトしません。" }
    var showOriginal: String { "原文を表示" }

    // MARK: 星图数据与页尾
    var staticDataLabel: String { "マップデータ" }
    func staticDataBuild(_ build: Int) -> String { "SDE ビルド \(build)" }
    var staticDataMissing: String { "マップデータがないため、星系と艦船を認識できません" }
    var footnote: String {
        "この機能はチャットログとゲームログを読むだけで、ゲームに入力を送ることはありません。"
            + "パイロット名と人数はメッセージの書式から推定するため、誤りがあることがあります。"
            + "オンラインでの確認は、その名前のキャラクターが存在することを示すだけで、"
            + "メッセージがそのキャラクターを指していることは保証しません。"
    }

    // MARK: 浮窗的标题与状态行
    func overlayTitle(_ character: String) -> String { "偵察 · \(character)" }
    var statusNoStaticData: String { "マップデータがありません" }
    var statusNoChannels: String { "偵察チャンネルが設定されていません" }
    var statusLocationUnknown: String { "現在地が不明です。右クリックで設定を開いて入力できます" }
    func statusUsingReference(_ system: String) -> String { "現在地が不明のため、基準星系 \(system) から計算" }
    func statusLocation(system: String, source: String, age: String) -> String {
        "現在地：\(system)（\(source)、\(age)前）"
    }

    // MARK: 浮窗每一行
    func ageSeconds(_ count: Int) -> String { "\(count) 秒" }
    func ageMinutes(_ count: Int) -> String { "\(count) 分" }
    func jumps(_ count: Int) -> String { "\(count) J" }
    var jumpsHere: String { "この星系" }
    func jumpsBeyond(_ limit: Int) -> String { "\(limit) J 超" }
    var jumpsUnreachable: String { "ゲートなし" }
    var jumpsUnknown: String { "?" }
    func count(_ value: Int) -> String { "×\(value)" }
    func countInferred(_ value: Int) -> String { "約 ×\(value)" }
    var clear: String { "クリア" }
    var noVisual: String { "視認なし" }

    // MARK: 人名核对
    var resolvePilotsToggle: String { "オンラインで名前を確認（ESI）" }
    var resolvePilotsHelp: String {
        "スペースを含む名前がいくつも続いているとき、それぞれがどのキャラクターかを CCP の ESI API に問い合わせます。"
            + "送信するのはそれらの単語だけで、発言者、チャンネル名、あなたのキャラクター名は送信しません。"
            + "1 単語の名前は問い合わせません。"
    }
    var pilotLookupLabel: String { "名前の確認" }
    func pilotLookupIdle(_ count: Int) -> String { "準備完了、キャラクター名 \(count) 件を保存済み" }
    var pilotLookupResolving: String { "確認中" }
    func pilotLookupWaiting(_ seconds: Int) -> String { "ESI に接続できません。\(seconds) 秒後に再試行します" }
    var clearPilotCache: String { "名前のキャッシュを消去" }
    func pilotCacheCount(_ count: Int) -> String { "キャラクター名 \(count) 件を保存済み" }
}
