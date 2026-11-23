// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图可见性规则，对应 macOS 的 Planning/VisibilityRules.swift。

//! 缩略图可见性。

use super::{FrontmostContext, PlannerInput};
use crate::model::EveClient;

/// 以下条件都不成立时缩略图可见：
///
/// 1. `session.hide_all` 为真。
/// 2. 角色名在 `profile.hidden_characters` 里（登录与未知客户端不受这条影响）。
/// 3. `hide_active_client_thumbnail` 为真，且前台正是这个客户端。
///    前台不是 EVE 时不看 `last_active_pid`，最后活动的客户端的缩略图会重新出现。
/// 4. `hide_when_eve_not_frontmost` 为真，前台是其他应用，且 `now - last_eve_context_at >= hide_delay_seconds`。
///    前台是本应用时不隐藏。有未到期战斗提醒的客户端不受这条影响，提醒结束后按原规则隐藏。
///    第 1～3 条不受提醒影响。
pub fn is_visible(client: &EveClient, input: &PlannerInput<'_>) -> bool {
    let behavior = &input.profile.behavior;
    let session = input.session;
    if session.hide_all {
        return false;
    }
    if let Some(name) = client.character_name()
        && input.profile.hidden_characters.iter().any(|n| n == name)
    {
        return false;
    }
    if behavior.hide_active_client_thumbnail && input.frontmost == FrontmostContext::Client(client.pid) {
        return false;
    }
    !(behavior.hide_when_eve_not_frontmost
        && input.frontmost == FrontmostContext::Other
        && input.now - session.last_eve_context_at >= behavior.hide_delay_seconds
        && !session.has_active_combat_alert(client.id, input.now))
}

/// 第 4 条规则尚未到期时返回到期时刻（`last_eve_context_at + hide_delay_seconds`），否则返回 `None`。
///
/// 规划器把它放进 `ThumbnailPlan::next_wake_at`，到时重算一次，让缩略图按时隐藏。
pub fn hide_deadline(input: &PlannerInput<'_>) -> Option<f64> {
    let behavior = &input.profile.behavior;
    if !behavior.hide_when_eve_not_frontmost || input.frontmost != FrontmostContext::Other {
        return None;
    }
    let deadline = input.session.last_eve_context_at + behavior.hide_delay_seconds;
    (input.now < deadline).then_some(deadline)
}
