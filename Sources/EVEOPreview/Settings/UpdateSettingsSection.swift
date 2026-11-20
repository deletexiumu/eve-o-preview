// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」页的「更新」一组（v1.1 设计 11.2 节）：「自动检查更新」与「自动安装更新」两个开关与说明、
// 当前版本、上次检查的时刻、状态行、「立即检查」按钮。控制器经 `model.coordinator.updates` 取得。
//
// WP-0 只建骨架：视图是 `EmptyView`；WP-4 实现。

import SwiftUI

/// 「通用」页的更新一组。
struct UpdateSettingsSection: View {
    /// 设置窗口的视图模型。
    let model: SettingsViewModel

    /// 骨架：不显示任何内容（WP-4 实现）。
    var body: some View {
        EmptyView()
    }
}
