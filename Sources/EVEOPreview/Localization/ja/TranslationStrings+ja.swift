// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的日文文字（docs/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按第 11 节的词表：オーバーレイ（浮窗）、チャンネル（频道）、モデルサービス（模型服务）；
// 钥匙串用 macOS 日文界面的官方名称「キーチェーン」。

import Foundation

/// 翻译域的日文文字。
struct TranslationStringsJA: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "選択したチャンネルの他言語のメッセージを翻訳します。" }
    var enableToggle: String { "翻訳オーバーレイを表示" }
    var statusLabel: String { "状態" }
    var statusOff: String { "オフ" }
    var statusIdle: String { "準備完了" }
    var statusTranslating: String { "翻訳中" }
    func statusWaiting(seconds: Int, reason: String) -> String { "\(seconds) 秒後に再試行：\(reason)" }
    func statusBlocked(_ reason: String) -> String { "一時停止中：\(reason)" }
    var retryNow: String { "今すぐ再試行" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "API アドレスが未入力です" }
    var failureMissingModel: String { "モデル名が未入力です" }
    var failureInvalidURL: String { "API アドレスの形式が正しくありません" }
    var failureInsecureHTTP: String { "http のアドレスはこの Mac とローカルネットワークでのみ使えます" }
    var failureMissingKey: String { "API キーが未入力です" }
    var failureKeychain: String { "キーチェーンからキーを読み取れません。「翻訳」ページで保存し直してください" }
    func failureUnauthorized(status: Int) -> String { "キーが拒否されました（HTTP \(status)）" }
    var failureNotFound: String { "API アドレスまたはモデル名が正しくありません（HTTP 404）" }
    var failureBalance: String { "残高が不足しています（HTTP 402）" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "リクエストが拒否されました（HTTP \(status)）"
            : "リクエストが拒否されました（HTTP \(status)）：\(message)"
    }
    var failureRateLimited: String { "リクエストが多すぎるか、利用枠を使い切りました（HTTP 429）" }
    func failureServer(status: Int) -> String { "モデルサービスでエラーが発生しました（HTTP \(status)）" }
    var failureNetwork: String { "モデルサービスに接続できません" }
    var failureMalformed: String { "モデルの回答が指定の形式ではありません" }
    var failureRefused: String { "モデルがこれらのメッセージの翻訳を断りました" }
    var failureTruncated: String { "モデルの回答が途中で切れました" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "翻訳するチャンネルを選択してください。" }
    var targetHeader: String { "翻訳先の言語" }
    var targetLanguage: String { "翻訳先" }
    var targetFollowUI: String { "インターフェイスの言語と同じ" }
    var showOriginal: String { "原文も表示" }
    var foreignOnly: String { "翻訳したメッセージだけを表示" }

    // MARK: 模型服务
    var modelHeader: String { "モデル" }
    var provider: String { "サービス" }
    var providerCustom: String { "その他（OpenAI 互換）" }
    var baseURL: String { "API アドレス" }
    var model: String { "モデル名" }
    var apiKey: String { "API キー" }
    var apiKeyStored: String { "キーチェーンに保存済み" }
    var apiKeyPlaceholder: String { "キーを貼り付けて「保存」をクリック" }
    var saveKey: String { "保存" }
    var deleteKey: String { "キーを削除" }
    var keyNotRequired: String { "このサービスにキーは不要です" }
    var keyOptional: String { "サービスがキーを必要とする場合に入力し、不要なら空欄のままにしてください。" }
    func keychainError(status: Int32) -> String { "キーチェーンの操作に失敗しました（\(status)）" }
    var test: String { "テスト" }
    var testing: String { "テスト中…" }
    func testSucceeded(_ text: String) -> String { "成功：\(text)" }
    func testFailed(_ reason: String) -> String { "失敗：\(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "翻訳キャッシュ" }
    func cacheCount(_ count: Int) -> String { "\(count) 件" }
    var clearCache: String { "キャッシュを消去" }
    var privacyNote: String {
        "これらのチャンネルのメッセージ本文は、選択したモデルサービスに送信されます。"
            + "キーはこの Mac のキーチェーンにのみ保存され、そのサービスにのみ送信されます。"
    }
    var costNote: String {
        "アクティブなクライアントのキャラクターが受け取ったメッセージだけを翻訳します。同じ文は一度だけ翻訳します。"
    }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "翻訳 · \(character)" }
    var statusNoChannels: String { "翻訳チャンネルが設定されていません" }
    var pending: String { "翻訳中…" }
    var failed: String { "未翻訳" }
}
