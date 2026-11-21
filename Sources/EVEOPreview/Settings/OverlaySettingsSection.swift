// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「预警」页与「翻译」页共用的浮窗设置（docs/design-intel-translate.md 第 10 节）：背景不透明度（0.2～1.0，
// 步长 0.05）、字号（10～24）、位置与尺寸（v1.2.1）、「恢复默认位置」按钮与手势说明。放在页的 Form 里，自成一组。
// 滑块立即写入（架构文档 7.4 节的约定）；取值范围取自 OverlayPanelSettings，越界的值由 ConfigValidator 夹取。
// 位置与尺寸：数字框显示浮窗实际使用的 frame（没保存过时是默认位置），回车或失去焦点时提交；
// 提交经 OverlayPlanner.editedFrame 取整、夹到尺寸上下限并拉回屏幕，再写成 frame（没保存过的也随之保存）。
// 布局锁定时也允许在这里改：锁定只防误拖，这里是明确的手工输入。
// 显示范围（v1.2.1）：竖排单选「始终显示 / 仅游戏内」，写法与热键的作用范围一致，立即写入。
// 文字取自 L10n.overlay。

import SwiftUI
import EVEOPreviewCore

/// 浮窗设置的一组控件。
struct OverlaySettingsSection: View {
    /// 绑定的浮窗设置（intel.overlay 或 translation.overlay）。
    @Binding var settings: OverlayPanelSettings
    /// 浮窗的种类，用来算没保存过时的默认位置。
    let kind: OverlayKind
    /// 当前屏幕，用来算默认位置与把手工输入的位置拉回屏幕。
    let screens: [ScreenInfo]

    /// 用绑定、种类与当前屏幕建这一组控件。
    init(settings: Binding<OverlayPanelSettings>, kind: OverlayKind, screens: [ScreenInfo]) {
        _settings = settings
        self.kind = kind
        self.screens = screens
    }

    var body: some View {
        // 每次求值时取一次文字表：切换界面语言后视图重建，自然取到新语言。
        let strings = L10n.overlay
        // 浮窗实际使用的 frame，与规划器的取法相同，拖动浮窗后这里随配置更新。
        let frame = OverlayPlanner.resolvedFrame(settings.frame, kind: kind, screens: screens)
        Section {
            Picker(strings.visibilityLabel, selection: $settings.visibility) {
                Text(strings.visibilityAlways).tag(OverlayVisibility.always)
                Text(strings.visibilityGameOnly).tag(OverlayVisibility.gameOnly)
            }
            .pickerStyle(.radioGroup)
            SliderRow(label: strings.opacity, value: $settings.opacity, range: OverlayPanelSettings.opacityRange,
                      step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" })
            SliderRow(label: strings.fontSize, value: $settings.fontSize, range: OverlayPanelSettings.fontSizeRange,
                      step: 1, format: { "\(NumberField.format($0)) \(L10n.settings.points)" })
            pairRow(strings.positionLabel, first: (frame.x, .x), second: (frame.y, .y), separator: ",", base: frame)
            pairRow(strings.sizeLabel, first: (frame.width, .width), second: (frame.height, .height), separator: "×",
                    base: frame)
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
        } footer: {
            Text(strings.frameHelp).foregroundStyle(.secondary)
        }
    }

    /// 一行两个数字框（X、Y 或宽、高），单位写在右侧。
    ///
    /// - Parameters:
    ///   - label: 左侧标签。
    ///   - first: 第一个框的当前值与对应字段。
    ///   - second: 第二个框的当前值与对应字段。
    ///   - separator: 两个框之间的符号。
    ///   - base: 改之前的 frame。
    private func pairRow(_ label: String, first: (Double, OverlayPlanner.FrameField),
                         second: (Double, OverlayPlanner.FrameField), separator: String,
                         base: ScreenRect) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                numberBox(first.0, field: first.1, base: base)
                Text(separator).foregroundStyle(.secondary)
                numberBox(second.0, field: second.1, base: base)
                Text(L10n.settings.points).foregroundStyle(.secondary)
            }
        }
    }

    /// 一个提交时生效的数字框：能解析成数字时按字段改 frame 并写入，否则恢复原值（草稿随当前值重置）。
    private func numberBox(_ value: Double, field: OverlayPlanner.FrameField, base: ScreenRect) -> some View {
        CommitTextField(placeholder: "", text: NumberField.format(value)) { text in
            guard let number = Double(text.trimmingCharacters(in: .whitespaces)),
                  let edited = OverlayPlanner.editedFrame(base, field: field, value: number, screens: screens)
            else { return }
            settings.frame = edited
        }
        .frame(width: 64)
        .multilineTextAlignment(.trailing)
    }
}
