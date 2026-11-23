// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键录制（架构文档 7.4 节，反馈文档 6.8 节）。点按钮开始录制：先暂停全局热键（否则组合键被自己的热键吞掉，
// 已绑定的鼠标按键也会先被事件监听吞掉），再用 NSEvent 的本地监听取键码或鼠标按钮号与修饰键。
// Escape 取消，Delete 清除，结束时恢复全局热键。
// 热键按键位（Carbon 虚拟键码）记录，不按字符，所以与键盘布局无关。
// 鼠标只录中键与侧键（按钮号 2～31）。本地监听只收到发给本应用的事件，所以录鼠标按键时指针应停在设置窗口内；
// 左键与右键不录制，左键点别处照常取消录制。
// 热键列表（HotkeyListEditor）在 HotkeyListEditor.swift。
// 同一时刻只有一个录制器在录：开始新的录制时，上一个自动取消。
// 设置窗口失去键盘焦点或关闭时也取消录制（cancelActive），否则全局热键会一直处于暂停状态。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 一个录制器的状态与本地键盘监听。
@MainActor
@Observable
final class HotkeyRecorder {
    /// 录制的结果。
    enum Outcome {
        /// 录到一个组合（键盘组合，或鼠标按键加修饰键）。
        case recorded(Hotkey)
        /// 用户按了 Delete：清除这一条。
        case cleared
        /// 用户按了 Escape，或录制被别的录制器打断。
        case cancelled
    }

    /// 是否正在录制。
    private(set) var isRecording = false

    /// NSEvent 本地监听的句柄；录制结束时移除。
    @ObservationIgnored private var monitor: Any?
    /// 录制结束的回调，只调用一次。
    @ObservationIgnored private var completion: ((Outcome) -> Void)?
    /// 视图模型，用来暂停与恢复全局热键；弱引用，窗口关闭后不延长它的生命周期。
    @ObservationIgnored private weak var model: SettingsViewModel?
    /// 当前正在录制的录制器。
    @ObservationIgnored private static weak var current: HotkeyRecorder?

    /// Escape 的虚拟键码（kVK_Escape）。
    private static let escapeKey: UInt16 = 53
    /// Delete 与 Forward Delete 的虚拟键码（kVK_Delete、kVK_ForwardDelete）。
    private static let deleteKeys: Set<UInt16> = [51, 117]

    /// 开始录制。结果经 completion 交回，之后录制器回到空闲。
    func start(model: SettingsViewModel, completion: @escaping (Outcome) -> Void) {
        HotkeyRecorder.current?.finish(.cancelled)
        HotkeyRecorder.current = self
        self.model = model
        self.completion = completion
        model.beginRecording()
        isRecording = true
        // 本地监听只收到发给本应用的按键与鼠标事件（设置窗口是 key 窗口时），返回 nil 表示吞掉。
        // 监听闭包不在主 actor 上声明，但 AppKit 在主线程调用它，所以用 assumeIsolated 进入主 actor；
        // NSEvent 不是 Sendable，先在外面取出键码、按钮号与修饰键再传进去。
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let consumed: Bool
            if event.type == .otherMouseDown {
                let button = event.buttonNumber
                consumed = MainActor.assumeIsolated { self?.handleMouse(button, flags: flags) ?? false }
            } else {
                let keyCode = event.keyCode
                consumed = MainActor.assumeIsolated { self?.handleKey(keyCode, flags: flags) ?? false }
            }
            return consumed ? nil : event
        }
    }

    /// 取消录制（视图消失或用户再次点按钮）。
    func cancel() {
        finish(.cancelled)
    }

    /// 取消当前正在录制的录制器（如果有）。设置窗口失去键盘焦点或关闭时调用：
    /// 此时本地键盘监听收不到按键，录制无法结束，全局热键会一直暂停。
    static func cancelActive() {
        current?.cancel()
    }

    /// 处理一次按键，返回 true 表示吞掉这次按键。
    private func handleKey(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard isRecording else { return false }
        let modifiers = HotkeyRecorder.modifiers(from: flags)
        if modifiers.isEmpty && keyCode == HotkeyRecorder.escapeKey {
            finish(.cancelled)
        } else if modifiers.isEmpty && HotkeyRecorder.deleteKeys.contains(keyCode) {
            finish(.cleared)
        } else {
            finish(.recorded(Hotkey(keyCode: keyCode, modifiers: modifiers)))
        }
        return true
    }

    /// 处理一次中键或侧键按下，返回 true 表示吞掉这次点击。按钮号不在 2～31 时不录制，照常放行。
    private func handleMouse(_ button: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard isRecording,
              let hotkey = Hotkey(mouseButton: button, modifiers: HotkeyRecorder.modifiers(from: flags)) else {
            return false
        }
        finish(.recorded(hotkey))
        return true
    }

    /// 结束录制：移除监听，恢复全局热键，交回结果。
    private func finish(_ outcome: Outcome) {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if HotkeyRecorder.current === self { HotkeyRecorder.current = nil }
        model?.endRecording()
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }

    /// AppKit 的修饰键 → Core 的修饰键。Caps Lock、Fn 等不参与热键。
    static func modifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var result = HotkeyModifiers()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

/// 一个热键的录制按钮。text 为 nil 时显示为「添加」按钮。
struct HotkeyRecorderView: View {
    /// 视图模型，用来暂停与恢复全局热键。
    let model: SettingsViewModel
    /// 当前的热键字符串；nil 表示这是「添加」按钮。
    let text: String?
    /// 录制结束的回调。
    let onFinish: (HotkeyRecorder.Outcome) -> Void

    /// 每个按钮有自己的录制器；@State 保证视图刷新时录制器不被重建。
    @State private var recorder = HotkeyRecorder()

    var body: some View {
        Button {
            if recorder.isRecording {
                recorder.cancel()
            } else {
                recorder.start(model: model, completion: onFinish)
            }
        } label: {
            Text(label)
                .frame(minWidth: 96)
                .foregroundStyle(recorder.isRecording ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(L10n.hotkeys.recorderHelp)
        .onDisappear { recorder.cancel() }
    }

    /// 按钮文字：录制中显示提示，否则显示热键的界面写法（不含作用范围，范围由旁边的菜单显示）；
    /// 解析不了的原样显示。
    private var label: String {
        if recorder.isRecording { return L10n.hotkeys.recordingPrompt }
        guard let text else { return L10n.hotkeys.addHotkey }
        return HotkeySpec(string: text)?.hotkey.displayString() ?? text
    }
}
