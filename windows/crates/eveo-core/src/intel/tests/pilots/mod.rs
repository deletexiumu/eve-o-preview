// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对的用例，对应 macOS 的 PilotLookupModelsTests、ESINameWireTests、PilotNameCacheTests、
// PilotLookupQueueTests 与 PilotSegmenterTests。人名都是虚构的；ESI 的答复按 E2～E5 手写，不联网。

mod cache;
mod models;
mod queue;
mod segmenter;
mod wire;

use std::collections::HashMap;

use crate::intel::pilots::PilotLookupOutcome;

/// 用（比较键，结果）的列表建结果表，测试里写起来比 HashMap 字面量短。
pub(super) fn outcomes(items: &[(&str, PilotLookupOutcome)]) -> HashMap<String, PilotLookupOutcome> {
    items
        .iter()
        .map(|(k, outcome)| ((*k).to_owned(), outcome.clone()))
        .collect()
}
