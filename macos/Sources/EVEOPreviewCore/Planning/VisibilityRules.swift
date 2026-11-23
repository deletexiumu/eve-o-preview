// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图可见性规则（架构文档 5.6 节）。

import Foundation

/// 缩略图可见性。
public enum VisibilityRules {
    /// 以下条件都不成立时缩略图可见：
    ///
    /// 1. `session.hideAll` 为真。
    /// 2. 角色名在 `profile.hiddenCharacters` 里（登录与未知客户端不受这条影响）。
    /// 3. `hideActiveClientThumbnail` 为真，且前台正是这个客户端（`frontmost == .client(pid:)`）。
    ///    前台不是 EVE 时不看 `lastActivePID`，最后活动的客户端的缩略图会重新出现。
    /// 4. `hideWhenEVENotFrontmost` 为真，前台是其他应用，且 `now - lastEVEContextAt >= hideDelaySeconds`。
    ///    前台是本应用（`.selfApp`）时不隐藏。有未到期战斗提醒的客户端不受这条影响（反馈文档 7.7 节），
    ///    提醒结束后按原规则隐藏。第 1～3 条不受提醒影响。
    public static func isVisible(client: EVEClient, input: PlannerInput) -> Bool {
        let behavior = input.profile.behavior
        if input.session.hideAll { return false }
        if let name = client.characterName, input.profile.hiddenCharacters.contains(name) { return false }
        if behavior.hideActiveClientThumbnail, input.frontmost == .client(pid: client.pid) { return false }
        if behavior.hideWhenEVENotFrontmost, input.frontmost == .other,
           input.now - input.session.lastEVEContextAt >= behavior.hideDelaySeconds,
           !input.session.hasActiveCombatAlert(client.id, now: input.now) {
            return false
        }
        return true
    }

    /// 第 4 条规则尚未到期时返回到期时刻（`lastEVEContextAt + hideDelaySeconds`），否则返回 nil。
    ///
    /// 规划器把它放进 `ThumbnailPlan.nextWakeAt`，App 到时重算一次，让缩略图按时隐藏。
    public static func hideDeadline(input: PlannerInput) -> Double? {
        let behavior = input.profile.behavior
        guard behavior.hideWhenEVENotFrontmost, input.frontmost == .other else { return nil }
        let deadline = input.session.lastEVEContextAt + behavior.hideDelaySeconds
        return input.now < deadline ? deadline : nil
    }
}
