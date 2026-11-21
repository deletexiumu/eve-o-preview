// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口共用的表单控件。
// 约定（架构文档 7.4 节）：开关、滑块、颜色立即写入；文本框只在回车或失去焦点时写入，
// 输入过程中的半截文字不会写进配置。

import SwiftUI
import EVEOPreviewCore

/// 只在提交时写入的文本框：回车或失去焦点时调用 onCommit；外部值变化时重置草稿。
struct CommitTextField: View {
    /// 占位文字。
    let placeholder: String
    /// 当前值。
    let text: String
    /// 提交回调，参数是草稿。
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        // 隐藏标签：grouped 样式的 Form 会把 TextField 的标题当成左侧标签，与外层的 LabeledContent 重复。
        TextField(placeholder, text: $draft)
            .labelsHidden()
            .focused($focused)
            .onSubmit { commit() }
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in draft = newValue }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    /// 草稿与当前值不同时才提交；提交后草稿先回到当前值。
    ///
    /// 提交改变了值时，随后 onChange(of: text) 会把草稿换成新值；提交被拒（无法解析）或被夹回原值时
    /// text 不变、不触发 onChange，不先复位的话框里会一直留着用户输入的那个值，每次失去焦点都再提交一次。
    private func commit() {
        guard draft != text else { return }
        onCommit(draft)
        draft = text
    }
}

/// 没有「当前值」的输入框：回车时提交；失去焦点时只在草稿自上次提交后改过时提交。
/// onCommit 返回真（提交成功）后清空草稿；返回假时草稿留着，再失去焦点也不重复提交。
///
/// 「预警」页的手动位置用它：CommitTextField 按「草稿与当前值不同」判断，当前值是空串时每次失去焦点都会把
/// 上次输入的星系名重新提交，盖掉之后游戏日志更新的位置（审查 m5）。
struct SubmitTextField: View {
    /// 占位文字。
    let placeholder: String
    /// 提交回调，参数是去掉首尾空白的草稿，返回是否成功。
    let onCommit: (String) -> Bool

    @State private var draft = ""
    /// 上次提交时的草稿；成功后清空。
    @State private var lastSubmitted = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .labelsHidden()
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused, draft != lastSubmitted { commit() }
            }
    }

    /// 草稿不为空时提交；成功后清空草稿。
    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastSubmitted = draft
        if onCommit(text) {
            draft = ""
            lastSubmitted = ""
        }
    }
}

/// 只在提交时写入的数字框，单位写在右侧。输入无法解析时恢复原值。
struct NumberField: View {
    /// 左侧标签。
    let label: String
    /// 数值的绑定。
    @Binding var value: Double
    /// 单位文字，如「点」。
    var unit: String = ""

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                CommitTextField(placeholder: "", text: NumberField.format(value)) { text in
                    if let number = Double(text.trimmingCharacters(in: .whitespaces)) { value = number }
                }
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 整数不带小数点，其余保留一位。
    ///
    /// 非有限值和超出 Int 范围的整数不能用 `Int(_:)` 转换（会崩溃），改用 `%.1f` 或 `%.0f` 格式化。
    /// 配置校验已把坐标夹到 ±100,000，这里只是兜底。
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        guard value.rounded() == value else { return String(format: "%.1f", value) }
        guard let integer = Int(exactly: value) else { return String(format: "%.0f", value) }
        return String(integer)
    }
}

/// 宽、高两个数字框。
struct SizeField: View {
    /// 左侧标签。
    let label: String
    /// 尺寸的绑定。
    @Binding var size: ScreenSize

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                numberBox(NumberField.format(size.width)) { size.width = $0 }
                Text("×").foregroundStyle(.secondary)
                numberBox(NumberField.format(size.height)) { size.height = $0 }
                Text(L10n.settings.points).foregroundStyle(.secondary)
            }
        }
    }

    /// 一个提交时生效的数字框。
    private func numberBox(_ text: String, set: @escaping (Double) -> Void) -> some View {
        CommitTextField(placeholder: "", text: text) { value in
            if let number = Double(value.trimmingCharacters(in: .whitespaces)) { set(number) }
        }
        .frame(width: 64)
        .multilineTextAlignment(.trailing)
    }
}

/// 滑块加数值显示。
struct SliderRow: View {
    /// 左侧标签。
    let label: String
    /// 数值的绑定。
    @Binding var value: Double
    /// 取值范围。
    let range: ClosedRange<Double>
    /// 步长。
    var step: Double = 1
    /// 数值的显示方式。
    var format: (Double) -> String = { NumberField.format($0) }

    var body: some View {
        LabeledContent(label) {
            HStack {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 160)
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// 整数的步进器。
struct IntStepperRow: View {
    /// 左侧标签。
    let label: String
    /// 数值的绑定。
    @Binding var value: Int
    /// 取值范围。
    let range: ClosedRange<Int>
    /// 单位文字。
    var unit: String = ""

    var body: some View {
        Stepper(value: $value, in: range) {
            LabeledContent(label) {
                Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)").monospacedDigit()
            }
        }
    }
}

/// 绑定到 `#RRGGBB` 字符串的取色器。
struct HexColorPicker: View {
    /// 左侧标签。
    let label: String
    /// 颜色字符串的绑定。
    @Binding var hex: String

    var body: some View {
        ColorPicker(label, selection: Binding(
            get: { Color(hex: hex) },
            set: { color in hex = color.hexString ?? hex }), supportsOpacity: false)
    }
}

/// 可以为空的颜色：为空时显示全局颜色并标明「默认」，有值时多一个恢复按钮。
struct OptionalHexColorPicker: View {
    /// 颜色字符串的绑定；nil 表示用默认颜色。
    @Binding var hex: String?
    /// 为空时显示的默认颜色。
    let fallback: String

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex ?? fallback) },
                set: { color in hex = color.hexString }), supportsOpacity: false)
                .labelsHidden()
            if hex == nil {
                Text(L10n.settings.defaultColor).foregroundStyle(.secondary).font(.caption)
            } else {
                Button(L10n.settings.reset) { hex = nil }
                    .controlSize(.small)
            }
        }
    }
}

/// 页顶部的标题与一句说明。
struct PageHeader: View {
    /// 标题。
    let title: String
    /// 说明；为空时不显示。
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.bold())
            if !subtitle.isEmpty {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 醒目的提示条，用于配置读取失败、演示模式等说明。
struct NoticeBanner: View {
    /// 提示文字。
    let text: String
    /// 图标（SF Symbols 名称）。
    var systemImage = "exclamationmark.triangle.fill"
    /// 图标颜色。
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
