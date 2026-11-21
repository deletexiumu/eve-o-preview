// SPDX-License-Identifier: GPL-3.0-or-later
//
// 给已有配置补上后来新增的默认值，每一项只补一次。
// 新建的配置方案经 `Profile.makeNew` 直接带上新默认值；已经存在的配置文件里对应的字段早已写成空值，
// 解码时分不清「从没设置过」与「用户清空了」，所以由应用在启动时按项补一次，补过的项记在 `state.json`
// （`AppState.appliedDefaults`），之后用户删掉也不会再补回来。
// 不借助配置结构版本（schemaVersion）做这件事：版本号一升，退回旧版应用时整个配置都读不了。

import Foundation

/// 一次性补上的默认值。
public enum OneTimeDefaults {
    /// 「全部隐藏」的默认热键 ⌃⌥⌘H（`GeneralHotkeys.defaultToggleHideAll`），v1.2 新增。
    public static let toggleHideAllHotkey = "hotkeys.toggleHideAll.ctrlOptCmdH"

    /// 全部的项，按加入的先后。以后新增的一次性默认值追加在末尾。
    public static let all: [String] = [toggleHideAllHotkey]

    /// 还没补过的项，保持 `all` 里的顺序。
    public static func pending(applied: [String]) -> [String] {
        all.filter { !applied.contains($0) }
    }

    /// 把 ids 里的各项补到配置的每个配置方案上；不认识的 id 忽略。配置原本就满足时原样返回。
    public static func apply(_ ids: [String], to config: AppConfig) -> AppConfig {
        var result = config
        for id in ids where id == toggleHideAllHotkey {
            for index in result.profiles.indices {
                addDefaultToggleHideAll(to: &result.profiles[index])
            }
        }
        return result
    }

    /// 「全部隐藏」还没有任何热键、且 ⌃⌥⌘H 没被这个方案的其他动作占用时，绑定默认热键。
    ///
    /// 用户已经给「全部隐藏」设过热键的，尊重用户的选择不再追加；
    /// ⌃⌥⌘H 已被别的动作占用时不追加，否则会出现「与某某重复」的提示。
    private static func addDefaultToggleHideAll(to profile: inout Profile) {
        guard profile.hotkeys.toggleHideAll.isEmpty,
              let wanted = HotkeySpec(string: GeneralHotkeys.defaultToggleHideAll)?.hotkey else { return }
        let taken = allHotkeyTexts(in: profile).contains { HotkeySpec(string: $0)?.hotkey == wanted }
        guard !taken else { return }
        profile.hotkeys.toggleHideAll = [GeneralHotkeys.defaultToggleHideAll]
    }

    /// 配置方案里全部热键字符串（全局热键、循环组、角色直达），用于判断某个组合是否已被占用。
    private static func allHotkeyTexts(in profile: Profile) -> [String] {
        var texts = profile.hotkeys.toggleHideAll + profile.hotkeys.minimizeAll + profile.hotkeys.cycleLoginClients
        for group in profile.cycleGroups {
            texts += group.forwardHotkeys + group.backwardHotkeys
        }
        for list in profile.characterHotkeys.values {
            texts += list
        }
        return texts
    }
}
