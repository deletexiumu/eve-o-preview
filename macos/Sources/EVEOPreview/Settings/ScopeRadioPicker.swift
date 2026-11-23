// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键作用范围的单选控件，「客户端」页与「切换与热键」页共用。
// 早先两页都用分段控件，用户分不清是「二选一」还是「两种可以同时生效」，也看不出「全局」是否包括游戏内。
// 这里改成竖排的单选按钮，每一项写名称加一句说明（全局：任何应用里都生效，包括游戏内；
// 仅游戏内：只在 EVE 窗口位于前台时生效），两页的文字与外观完全一致。

import SwiftUI
import EVEOPreviewCore

/// 热键作用范围的单选按钮组。
///
/// 选中值是 `Value`：「切换与热键」页的默认范围总有值，用 `HotkeyScope`；
/// 「客户端」页在各快捷键范围不一致时两项都不选中，用 `HotkeyScope?`。
struct ScopeRadioPicker<Value: Hashable>: View {
    /// 左侧的标签。
    let label: String
    /// 选中的范围。
    let selection: Binding<Value>
    /// 把范围转成选中值的类型，用作每一项的 tag。
    private let tag: (HotkeyScope) -> Value

    var body: some View {
        Picker(label, selection: selection) {
            Text(L10n.hotkeys.scopeGlobalOption).tag(tag(.global))
            Text(L10n.hotkeys.scopeGameOption).tag(tag(.game))
        }
        .pickerStyle(.radioGroup)
    }
}

extension ScopeRadioPicker where Value == HotkeyScope {
    /// 选中值总有一项的版本（默认范围）。
    init(label: String, selection: Binding<HotkeyScope>) {
        self.label = label
        self.selection = selection
        self.tag = { $0 }
    }
}

extension ScopeRadioPicker where Value == HotkeyScope? {
    /// 选中值可以为空的版本（各快捷键范围不一致时两项都不选中）。
    init(label: String, selection: Binding<HotkeyScope?>) {
        self.label = label
        self.selection = selection
        self.tag = { .some($0) }
    }
}
