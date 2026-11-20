// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「通用」页的「诊断」一组（v1.1 设计 11.2 节）：「详细日志」开关与说明、日志文件的位置与
// 「在访达中显示日志」按钮、「报告问题…」按钮。控制器经 `model.coordinator.problemReport` 取得。
//
// WP-0 只建骨架：视图是 `EmptyView`；WP-2 实现。

import SwiftUI

/// 「通用」页的诊断一组。
struct DiagnosticsSettingsSection: View {
    /// 设置窗口的视图模型。
    let model: SettingsViewModel

    /// 骨架：不显示任何内容（WP-2 实现）。
    var body: some View {
        EmptyView()
    }
}
