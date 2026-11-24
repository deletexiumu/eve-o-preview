// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译的界面文字，对应 macOS 的 TranslationLineFormatter.swift 与 TranslationStrings+Status.swift：
// - TranslationFormatter：用 eveo-l10n 的翻译文字实现 Core 的 TranslationLineFormatting（时间与两个状态词）。
//   时间是日志里的 EVE 时间（UTC）HH:mm，与游戏聊天窗口一致，只用整数运算，不依赖时区。
// - issue_text、failure_text、status_text：把接口问题、失败与队列状态换成文字，浮窗状态行与「翻译」页共用。
//   Rejected 的说明（服务给的原话）只出现在这里，不写进日志。
// - failure_log_name：失败在诊断日志里的名字，只有种类与状态码。
// - channel_display_name：频道的显示名，内置频道取本地化的名字（与设置里的频道列表一致）。

//! 翻译的界面文字与日志名。

use eveo_core::model::{AppLanguage, ChannelRef};
use eveo_core::translation::presenter::TranslationLineFormatting;
use eveo_core::translation::{EndpointIssue, Failure, TranslationStatus};

/// 翻译浮窗的格式器。按建它时的语言取文字；换语言后控制器下一次生成内容时新建一个。
#[derive(Debug, Clone, Copy)]
pub struct TranslationFormatter {
    /// 界面语言。
    pub language: AppLanguage,
}

impl TranslationLineFormatting for TranslationFormatter {
    /// EVE 时间（UTC）的 HH:mm；非有限值或大得离谱的值显示 `--:--`。
    fn time(&self, utc: f64) -> String {
        if !utc.is_finite() || utc.abs() >= 1e15 {
            return "--:--".to_owned();
        }
        // rem_euclid 让 1970 年以前（负数）的时刻也落在 0～86399。
        let day = (utc.floor() as i64).rem_euclid(86_400);
        format!("{:02}:{:02}", day / 3_600, day / 60 % 60)
    }

    /// 「翻译中…」。
    fn pending(&self) -> String {
        eveo_l10n::translation(self.language).pending().to_owned()
    }

    /// 「未翻译」。
    fn failed(&self) -> String {
        eveo_l10n::translation(self.language).failed().to_owned()
    }
}

/// 接口设置问题的文字。
pub fn issue_text(language: AppLanguage, issue: EndpointIssue) -> String {
    let text = eveo_l10n::translation(language);
    match issue {
        EndpointIssue::MissingBaseUrl => text.failure_missing_base_url(),
        EndpointIssue::MissingModel => text.failure_missing_model(),
        EndpointIssue::InvalidUrl => text.failure_invalid_url(),
        EndpointIssue::InsecureRemoteHttp => text.failure_insecure_http(),
    }
    .to_owned()
}

/// 失败原因的文字。
pub fn failure_text(language: AppLanguage, failure: &Failure) -> String {
    let text = eveo_l10n::translation(language);
    match failure {
        Failure::NotConfigured(issue) => issue_text(language, *issue),
        Failure::MissingKey => text.failure_missing_key().to_owned(),
        Failure::KeychainUnavailable => text.failure_keychain().to_owned(),
        Failure::Unauthorized(status) => text.failure_unauthorized(i64::from(*status)),
        Failure::NotFound => text.failure_not_found().to_owned(),
        Failure::InsufficientBalance => text.failure_balance().to_owned(),
        Failure::Rejected { status, message } => text.failure_rejected(i64::from(*status), message),
        Failure::RateLimited(_) => text.failure_rate_limited().to_owned(),
        Failure::Server(status) => text.failure_server(i64::from(*status)),
        Failure::Network(_) => text.failure_network().to_owned(),
        Failure::MalformedAnswer => text.failure_malformed().to_owned(),
        Failure::Refused => text.failure_refused().to_owned(),
        Failure::Truncated => text.failure_truncated().to_owned(),
    }
}

/// 队列状态的文字；now 是墙上时钟的秒数，用来算还要等几秒（向上取整）。
pub fn status_text(language: AppLanguage, status: &TranslationStatus, now: f64) -> String {
    let text = eveo_l10n::translation(language);
    match status {
        TranslationStatus::Off => text.status_off().to_owned(),
        TranslationStatus::Idle => text.status_idle().to_owned(),
        TranslationStatus::Translating => text.status_translating().to_owned(),
        TranslationStatus::Waiting { until, reason } => {
            let seconds = crate::chat::whole_seconds((until - now).ceil());
            text.status_waiting(seconds, &failure_text(language, reason))
        }
        TranslationStatus::Blocked(reason) => text.status_blocked(&failure_text(language, reason)),
    }
}

/// 失败在诊断日志里的名字：只有种类、状态码与等待秒数，不含服务给的说明。
/// 网络失败带系统给的说明（WinHTTP 的错误码），其中没有地址与请求内容。
pub fn failure_log_name(failure: &Failure) -> String {
    match failure {
        Failure::NotConfigured(_) => "notConfigured".to_owned(),
        Failure::MissingKey => "missingKey".to_owned(),
        Failure::KeychainUnavailable => "keychainUnavailable".to_owned(),
        Failure::Unauthorized(status) => format!("unauthorized({status})"),
        Failure::NotFound => "notFound".to_owned(),
        Failure::InsufficientBalance => "insufficientBalance".to_owned(),
        Failure::Rejected { status, .. } => format!("rejected({status})"),
        Failure::RateLimited(Some(seconds)) => {
            format!("rateLimited({}s)", crate::chat::whole_seconds(*seconds))
        }
        Failure::RateLimited(None) => "rateLimited(no retry-after)".to_owned(),
        Failure::Server(status) => format!("server({status})"),
        Failure::Network(reason) => format!("network({reason})"),
        Failure::MalformedAnswer => "malformedAnswer".to_owned(),
        Failure::Refused => "refused".to_owned(),
        Failure::Truncated => "truncated".to_owned(),
    }
}

/// 频道的显示名：内置频道按界面语言显示本地化的名字；其余显示名字，名字为空时显示 ID。
pub fn channel_display_name(channel: &ChannelRef, language: AppLanguage) -> String {
    // 内置频道的名字随客户端语言变（Local、本地……），配置里存的英文名不一定是用户看到的。
    if channel.is_built_in() {
        let text = eveo_l10n::overlay(language);
        let id = channel.id.as_deref().unwrap_or_default().to_lowercase();
        let built_in = match id.as_str() {
            "local" => Some(text.built_in_local()),
            "corp" => Some(text.built_in_corp()),
            "alliance" => Some(text.built_in_alliance()),
            "fleet" => Some(text.built_in_fleet()),
            _ => None,
        };
        if let Some(name) = built_in {
            return name.to_owned();
        }
    }
    let name = channel.name.trim();
    if name.is_empty() {
        channel.id.clone().unwrap_or_default()
    } else {
        name.to_owned()
    }
}
