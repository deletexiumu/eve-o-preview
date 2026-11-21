// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页与「翻译」页共用的浮窗设置（docs/design-intel-translate.md 第 10 节）：背景不透明度（0.2～1.0，
// 步长 0.05）、字号（10～24）、「恢复默认位置」按钮与手势说明。放在页的 Form 里，自成一组。
// 滑块立即写入（架构文档 7.4 节的约定）；取值范围取自 OverlayPanelSettings，越界的值由 ConfigValidator 夹取。
// 文字取自 L10n.overlay。

import SwiftUI
import EVEOPreviewCore

/// 浮窗设置的一组控件。
struct OverlaySettingsSection: View {
    /// 绑定的浮窗设置（intel.overlay 或 translation.overlay）。
    @Binding var settings: OverlayPanelSettings

    /// 用绑定建这一组控件。
    init(settings: Binding<OverlayPanelSettings>) {
        _settings = settings
    }

    var body: some View {
        // 每次求值时取一次文字表：切换界面语言后视图重建，自然取到新语言。
        let strings = L10n.overlay
        Section {
            SliderRow(label: strings.opacity, value: $settings.opacity, range: OverlayPanelSettings.opacityRange,
                      step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
            SliderRow(label: strings.fontSize, value: $settings.fontSize, range: OverlayPanelSettings.fontSizeRange,
                      step: 1, format: { "\(NumberField.format($0)) \(L10n.settings.points)" })
            // 没有保存过位置时按钮置灰：浮窗已经在默认位置。
            LabeledContent {
                Button(strings.resetFrame) { settings.frame = nil }
                    .disabled(settings.frame == nil)
            } label: {
                Text(strings.gestureHelp)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(strings.overlayHeader)
        }
    }
}
