// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译规则的用例，对应 macOS 的 TranslationProvidersTests、TranslationRulesTests、TranslationPromptTests 与
// TranslationWireTests，以及 TranslationCacheTests、TranslationQueueTests、TranslationPresenterTests。
// 术语匹配与情报分段都手工构造，不依赖星图数据。人名、频道名与 Key 都是编造的。

mod cache;
mod presenter;
mod prompt;
mod providers;
mod queue;
mod rules;
mod switcher;
mod wire;

use super::{Phase, TranslationItem};
use crate::chat_log::ChatMessage;
use crate::static_data::matcher::{TermKind, TermMatch};

/// 建一条消息。收听者、频道与说话人都是虚构的。
pub(super) fn message(text: &str) -> ChatMessage {
    message_at(text, "Pilot Alpha", 1_000_000.0)
}

/// 建一条指定收听者与时间的消息。
pub(super) fn message_at(text: &str, listener: &str, time: f64) -> ChatMessage {
    ChatMessage {
        listener: listener.to_owned(),
        channel_id: "player_chat.Demo".to_owned(),
        channel_name: "chat.Demo".to_owned(),
        time,
        speaker: "Vex Oran".to_owned(),
        text: text.to_owned(),
        is_backfill: false,
    }
}

/// 建一条排队中的条目。
pub(super) fn item(id: u64, text: &str) -> TranslationItem {
    item_with(id, text, Phase::Pending)
}

/// 建一条指定阶段的条目。
pub(super) fn item_with(id: u64, text: &str, phase: Phase) -> TranslationItem {
    TranslationItem {
        id,
        message: message(text),
        phase,
    }
}

/// 在 text 里找 word 第一次出现的范围，建一处术语匹配。localized 是 (语言代码, 名称) 的列表。
pub(super) fn term(
    word: &str,
    text: &str,
    kind: TermKind,
    english: &str,
    localized: &[(&str, &str)],
) -> TermMatch {
    let start = text.find(word).expect("测试文字里应有这个词");
    TermMatch {
        range: start..start + word.len(),
        kind,
        english: english.to_owned(),
        localized: localized
            .iter()
            .map(|(code, name)| ((*code).to_owned(), (*name).to_owned()))
            .collect(),
    }
}
