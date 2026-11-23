// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域的韩文文字（docs/macos/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按第 11 节的词表：오버레이（浮窗）、채널（频道）、모델 서비스（模型服务）；
// 钥匙串用 macOS 韩文界面的官方名称「키체인」。

import Foundation

/// 翻译域的韩文文字。
struct TranslationStringsKO: TranslationStrings {
    // MARK: 页头与状态
    var pageSubtitle: String { "선택한 채널에서 다른 언어로 된 메시지를 번역합니다." }
    var enableToggle: String { "번역 오버레이 표시" }
    var statusLabel: String { "상태" }
    var statusOff: String { "꺼짐" }
    var statusIdle: String { "준비됨" }
    var statusTranslating: String { "번역 중" }
    func statusWaiting(seconds: Int, reason: String) -> String { "\(seconds)초 후 다시 시도: \(reason)" }
    func statusBlocked(_ reason: String) -> String { "일시 중지됨: \(reason)" }
    var retryNow: String { "지금 다시 시도" }

    // MARK: 失败的原因
    var failureMissingBaseURL: String { "API 주소가 입력되지 않았습니다" }
    var failureMissingModel: String { "모델 이름이 입력되지 않았습니다" }
    var failureInvalidURL: String { "API 주소 형식이 올바르지 않습니다" }
    var failureInsecureHTTP: String { "http 주소는 이 Mac과 로컬 네트워크에서만 사용할 수 있습니다" }
    var failureMissingKey: String { "API 키가 입력되지 않았습니다" }
    var failureKeychain: String { "키체인에서 키를 읽을 수 없습니다. '번역' 페이지에서 다시 저장하세요" }
    func failureUnauthorized(status: Int) -> String { "키가 거부되었습니다(HTTP \(status))" }
    var failureNotFound: String { "API 주소 또는 모델 이름이 올바르지 않습니다(HTTP 404)" }
    var failureBalance: String { "잔액이 부족합니다(HTTP 402)" }
    func failureRejected(status: Int, message: String) -> String {
        message.isEmpty ? "요청이 거부되었습니다(HTTP \(status))" : "요청이 거부되었습니다(HTTP \(status)): \(message)"
    }
    var failureRateLimited: String { "요청이 너무 많거나 사용량을 모두 소진했습니다(HTTP 429)" }
    func failureServer(status: Int) -> String { "모델 서비스 오류(HTTP \(status))" }
    var failureNetwork: String { "모델 서비스에 연결할 수 없습니다" }
    var failureMalformed: String { "모델이 요구한 형식으로 답하지 않았습니다" }
    var failureRefused: String { "모델이 이 메시지들의 번역을 거부했습니다" }
    var failureTruncated: String { "모델의 답변이 잘렸습니다" }

    // MARK: 频道与目标语言
    var channelsHelp: String { "번역할 채널을 선택하세요." }
    var targetHeader: String { "번역할 언어" }
    var targetLanguage: String { "번역 언어" }
    var targetFollowUI: String { "인터페이스 언어와 같게" }
    var showOriginal: String { "원문도 표시" }
    var foreignOnly: String { "번역된 메시지만 표시" }

    // MARK: 模型服务
    var modelHeader: String { "모델" }
    var provider: String { "서비스" }
    var providerCustom: String { "기타(OpenAI 호환)" }
    var baseURL: String { "API 주소" }
    var model: String { "모델 이름" }
    var apiKey: String { "API 키" }
    var apiKeyStored: String { "키체인에 저장됨" }
    var apiKeyPlaceholder: String { "키를 붙여넣고 '저장'을 클릭하세요" }
    var saveKey: String { "저장" }
    var deleteKey: String { "키 삭제" }
    var keyNotRequired: String { "이 서비스는 키가 필요 없습니다" }
    var keyOptional: String { "서비스에 키가 필요하면 입력하고, 필요 없으면 비워 두세요." }
    func keychainError(status: Int32) -> String { "키체인 작업 실패(\(status))" }
    var test: String { "테스트" }
    var testing: String { "테스트 중…" }
    func testSucceeded(_ text: String) -> String { "성공: \(text)" }
    func testFailed(_ reason: String) -> String { "실패: \(reason)" }

    // MARK: 缓存与说明
    var cacheHeader: String { "번역 캐시" }
    func cacheCount(_ count: Int) -> String { "\(count)개" }
    var clearCache: String { "캐시 지우기" }
    var privacyNote: String {
        "이 채널들의 메시지 본문은 선택한 모델 서비스로 전송됩니다. "
            + "키는 이 Mac의 키체인에만 저장되며 해당 서비스로만 전송됩니다."
    }
    var costNote: String { "활성 클라이언트의 캐릭터가 받은 메시지만 번역합니다. 같은 문장은 한 번만 번역합니다." }

    // MARK: 浮窗
    func overlayTitle(_ character: String) -> String { "번역 · \(character)" }
    var statusNoChannels: String { "번역 채널이 설정되지 않았습니다" }
    func statusNoLogFiles(_ channels: [String]) -> String {
        "최근 48시간 동안 EVE가 이 캐릭터의 \(channels.joined(separator: ", ")) 채팅 로그를 기록하지 않았습니다"
    }
    func statusNoLogFilesBuiltIn(_ channels: [String]) -> String {
        "EVE가 \(channels.joined(separator: ", ")) 로그를 쓰지 않았습니다. 영어가 아닌 클라이언트는 시스템 채널을 기록하지 않을 수 있으니 EVE 언어를 English로 바꾸세요"
    }
    var pending: String { "번역 중…" }
    var failed: String { "번역 안 됨" }
}
