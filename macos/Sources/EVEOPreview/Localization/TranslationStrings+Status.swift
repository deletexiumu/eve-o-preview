// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译域文字的补充：把失败、接口问题与队列状态换成文字，各语言共用。
// 协议与各语言的文字由 shared/l10n 生成（Generated/TranslationStrings.swift）。

import Foundation
import EVEOPreviewCore

extension TranslationStrings {
    /// 接口设置问题的文字。
    func issueText(_ issue: TranslationEndpointIssue) -> String {
        switch issue {
        case .missingBaseURL: return failureMissingBaseURL
        case .missingModel: return failureMissingModel
        case .invalidURL: return failureInvalidURL
        case .insecureRemoteHTTP: return failureInsecureHTTP
        }
    }

    /// 失败原因的文字。rejected 的说明只在这里出现，不写进日志（7.5 节）。
    func failureText(_ failure: TranslationFailure) -> String {
        switch failure {
        case .notConfigured(let issue): return issueText(issue)
        case .missingKey: return failureMissingKey
        case .keychainUnavailable: return failureKeychain
        case .unauthorized(let status): return failureUnauthorized(status: status)
        case .notFound: return failureNotFound
        case .insufficientBalance: return failureBalance
        case .rejected(let status, let message): return failureRejected(status: status, message: message)
        case .rateLimited: return failureRateLimited
        case .server(let status): return failureServer(status: status)
        case .network: return failureNetwork
        case .malformedAnswer: return failureMalformed
        case .refused: return failureRefused
        case .truncated: return failureTruncated
        }
    }

    /// 队列状态的文字；now 是墙上时钟的秒数，用来算还要等几秒。
    func statusText(_ status: TranslationStatus, now: Double) -> String {
        switch status {
        case .off: return statusOff
        case .idle: return statusIdle
        case .translating: return statusTranslating
        case .waiting(let until, let reason):
            let seconds = Int(max(0, (until - now).rounded(.up)))
            return statusWaiting(seconds: seconds, reason: failureText(reason))
        case .blocked(let reason): return statusBlocked(failureText(reason))
        }
    }
}
