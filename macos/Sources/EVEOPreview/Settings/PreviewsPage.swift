// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「预览与布局」页（架构文档 7.4 节）。按主题分成 6 组：
// 尺寸、外观（透明度、标题、边框、高亮）、悬停放大、行为（置顶、隐藏规则）、布局（吸附、锁定）、捕获与登录位置。
// 取值范围与 ConfigValidator 一致；超出范围的输入写入后会被夹回。

import SwiftUI
import EVEOPreviewCore

/// 「预览与布局」页。
struct PreviewsPage: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                SizeField(label: L10n.settings.defaultSize, size: model.binding(\.thumbnail.defaultSize))
                SizeField(label: L10n.settings.minimumSize, size: model.binding(\.thumbnail.minimumSize))
                SizeField(label: L10n.settings.maximumSize, size: model.binding(\.thumbnail.maximumSize))
                // 「统一尺寸」只清尺寸记录，位置保留，各缩略图回到默认尺寸。
                LabeledContent("") {
                    Button(L10n.settings.unifySizes) { model.unifyThumbnailSizes() }
                }
            } header: {
                PageHeader(title: L10n.settings.pagePreviews, subtitle: L10n.settings.previewsSubtitle)
            }
            AppearanceSection(model: model)
            ZoomSection(model: model)
            BehaviorSection(model: model)
            CaptureSection(model: model)
        }
        .formStyle(.grouped)
    }
}

/// 外观：透明度、标题、边框、高亮边框。
private struct AppearanceSection: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Section(L10n.settings.appearanceHeader) {
            // 透明度只作用于未悬停的缩略图；悬停时总是不透明。范围 20%～100%。
            SliderRow(label: L10n.settings.opacity, value: model.binding(\.thumbnail.opacity), range: 0.2...1.0,
                      step: 0.05, format: { String(format: "%.0f%%", $0 * 100) })
            Toggle(L10n.settings.showTitle, isOn: model.binding(\.overlay.showTitle))
            SliderRow(label: L10n.settings.titleFontSize, value: model.binding(\.overlay.titleFontSize), range: 8...36)
            HexColorPicker(label: L10n.settings.titleColor, hex: model.binding(\.overlay.titleColor))
            // 每个缩略图都有的中性色边框（反馈文档 4.3 节）。活动客户端的高亮边框盖过它；开关关闭时颜色与粗细置灰。
            Toggle(L10n.settings.borderEnabled, isOn: model.binding(\.overlay.borderEnabled))
            HexColorPicker(label: L10n.settings.borderColor, hex: model.binding(\.overlay.borderColor))
                .disabled(!model.profile.overlay.borderEnabled)
            IntStepperRow(label: L10n.settings.borderThickness, value: model.binding(\.overlay.borderThickness),
                          range: 1...6, unit: L10n.settings.points)
                .disabled(!model.profile.overlay.borderEnabled)
            // 全局高亮颜色；客户端页可以按角色覆盖。
            Toggle(L10n.settings.highlightEnabled, isOn: model.binding(\.overlay.highlightEnabled))
            HexColorPicker(label: L10n.settings.highlightColor, hex: model.binding(\.overlay.highlightColor))
            IntStepperRow(label: L10n.settings.highlightThickness, value: model.binding(\.overlay.highlightThickness),
                          range: 1...6, unit: L10n.settings.points)
        }
    }
}

/// 悬停放大：开关、倍数、锚点。
private struct ZoomSection: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Section(L10n.settings.zoomHeader) {
            Toggle(L10n.settings.zoomEnabled, isOn: model.binding(\.thumbnail.zoomEnabled))
            // 放大后的尺寸不受最大尺寸限制；锚点决定放大时哪一点不动。
            IntStepperRow(label: L10n.settings.zoomFactor, value: model.binding(\.thumbnail.zoomFactor), range: 2...10,
                          unit: "×")
            Picker(L10n.settings.zoomAnchor, selection: model.binding(\.thumbnail.zoomAnchor)) {
                ForEach(ZoomAnchor.allCases, id: \.self) { anchor in
                    Text(L10n.settings.anchorName(anchor)).tag(anchor)
                }
            }
        }
    }
}

/// 行为与布局：置顶、两条隐藏规则、吸附、宽高比、锁定布局。
private struct BehaviorSection: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Section(L10n.settings.behaviorHeader) {
            Toggle(L10n.settings.alwaysOnTop, isOn: model.binding(\.behavior.alwaysOnTop))
            Toggle(L10n.settings.hideActiveClient, isOn: model.binding(\.behavior.hideActiveClientThumbnail))
            Toggle(L10n.settings.hideWhenNotEVE, isOn: model.binding(\.behavior.hideWhenEVENotFrontmost))
            SliderRow(label: L10n.settings.hideDelay, value: model.binding(\.behavior.hideDelaySeconds), range: 0...10,
                      step: 0.5, format: { L10n.settings.seconds($0) })
                // 延迟只对「离开 EVE 时隐藏」有意义，开关关闭时置灰。
                .disabled(!model.profile.behavior.hideWhenEVENotFrontmost)
        }
        Section(L10n.settings.layoutHeader) {
            Toggle(L10n.settings.snapEnabled, isOn: model.binding(\.thumbnail.snapEnabled))
            Toggle(L10n.settings.lockAspectRatio, isOn: model.binding(\.thumbnail.lockAspectRatio))
            // 锁定布局只禁止移动与缩放，切换、最小化、菜单照常。
            Toggle(L10n.settings.lockLayout, isOn: model.binding(\.behavior.lockLayout))
            Text(L10n.settings.gestureHint).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 捕获与登录位置：帧率、标题栏裁剪高度、轮询间隔、登录缩略图位置。
private struct CaptureSection: View {
    /// 视图模型。
    let model: SettingsViewModel

    var body: some View {
        Section(L10n.settings.captureHeader) {
            // 帧率越高越耗电；捕获分辨率跟随缩略图尺寸，不跟随源窗口。
            SliderRow(label: L10n.settings.frameRate, value: intAsDouble(model.binding(\.capture.frameRate)),
                      range: 1...60, format: { L10n.settings.fps($0) })
            // 标题栏裁剪按点计；源窗口是全屏时规划器自动不裁。默认 28 点是估计值（架构文档 V6）。
            SliderRow(label: L10n.settings.titleBarCrop, value: model.binding(\.capture.titleBarCropHeight),
                      range: 0...60, format: { "\(Int($0)) \(L10n.settings.points)" })
            // 轮询间隔决定登录改名、客户端退出最迟多久被发现；Core 的取值范围是 300～2000 毫秒。
            SliderRow(label: L10n.settings.pollInterval, value: intAsDouble(model.generalBinding(\.pollIntervalMs)),
                      range: 300...2000, step: 100, format: { L10n.settings.milliseconds($0) })
            // 登录客户端的缩略图从这里起层叠摆放；拖动登录缩略图也会改这个位置。
            NumberField(label: L10n.settings.loginPositionX, value: model.binding(\.loginPosition.x),
                        unit: L10n.settings.points)
            NumberField(label: L10n.settings.loginPositionY, value: model.binding(\.loginPosition.y),
                        unit: L10n.settings.points)
        }
    }

    /// 整数绑定转成滑块用的浮点绑定，写回时四舍五入。
    private func intAsDouble(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }
}
