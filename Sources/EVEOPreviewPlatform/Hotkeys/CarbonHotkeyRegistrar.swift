// SPDX-License-Identifier: GPL-3.0-or-later
//
// 全局热键注册（架构文档 6.5 节）。用 Carbon 的 RegisterEventHotKey，不装键盘钩子，
// 不需要辅助功能或输入监控权限。热键触发后按键不再传给前台应用。
// 回调在主线程触发（应用事件目标由主线程的事件循环分发），所以用 MainActor.assumeIsolated。
//
// 第一轮反馈（反馈文档 6.5 节）：本类改成 SystemHotkeyRegistrar 内部的键盘后端，不再实现 HotkeyRegistrar 协议。
// 它只按吩咐注册与注销，「哪些绑定应启用」（作用范围、暂停）由 SystemHotkeyRegistrar 决定。
//
// 代数：HotkeyPlanner 每次规划都从 1 起重新编号。热键事件先排进主线程的事件队列，replaceAll 之后才分发时，
// 旧编号会落到新规划里别的动作上。所以 EventHotKeyID.id 的高 8 位放代数、低 24 位放绑定 id，
// 回调里代数不是当前代数、或这个 id 已注销时丢弃。只有 replaceAll 开始新的一代；
// 前台变化、暂停与恢复时注销再注册热键，编号不变，不改代数。编码规则在 Core 的 CarbonHotkeyID。

import Carbon.HIToolbox
import EVEOPreviewCore
import os

/// 基于 Carbon 热键的键盘后端。全部方法在主线程调用。
@MainActor final class CarbonHotkeyRegistrar {
    /// `EventHotKeyID.signature`：四字符码 `EVOP`，用来认出本应用注册的热键。
    nonisolated static let signature: OSType = 0x4556_4F50

    /// 热键触发时在主线程调用，参数是 `HotkeyBinding.id`。由 SystemHotkeyRegistrar 在建立时设置。
    var onHotkey: (@MainActor (HotkeyBinding.ID) -> Void)?

    /// 已注册的热键引用，按绑定 id 索引。
    private var refs: [UInt32: EventHotKeyRef] = [:]
    /// 当前代数，取值 0～255，写进 EventHotKeyID.id 的高 8 位。
    private var generation: UInt32 = 0
    /// 已安装的事件处理器。
    private var handlerRef: EventHandlerRef?
    /// 日志。
    private let log = Logger(subsystem: PlatformLog.subsystem, category: "Hotkeys")

    /// 建一个键盘后端，并在应用事件目标上安装热键事件处理器。
    init() {
        installHandler()
    }

    /// 已注册的绑定 id。
    var registeredIDs: Set<UInt32> {
        Set(refs.keys)
    }

    /// 注册一条键盘绑定，返回失败记录；成功或已注册时返回 nil。鼠标绑定不归本类，直接忽略。
    func register(_ binding: HotkeyBinding) -> HotkeyRegistrationFailure? {
        guard refs[binding.id] == nil, let keyCode = binding.hotkey.keyCode else { return nil }
        // 绑定 id 超出低 24 位时编码不下，当作注册失败（实际规划不会出现）。
        guard let rawID = CarbonHotkeyID.encode(generation: generation, bindingID: binding.id) else {
            log.error("热键编号 \(binding.id) 超出范围，不注册")
            return HotkeyRegistrationFailure(binding: binding, reason: .registrationRejected(status: OSStatus(paramErr)))
        }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: rawID)
        let status = RegisterEventHotKey(UInt32(keyCode), Self.carbonModifiers(binding.hotkey.modifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[binding.id] = ref
            return nil
        }
        log.error("热键注册失败：\(binding.hotkey.stringValue(), privacy: .public) 返回 \(status)")
        return HotkeyRegistrationFailure(binding: binding, reason: .registrationRejected(status: status))
    }

    /// 注销指定 id 的热键；没有注册的 id 忽略。
    func unregister(ids: some Sequence<UInt32>) {
        for id in ids {
            if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        }
    }

    /// 注销全部已注册的热键。
    func unregisterAll() {
        unregister(ids: Array(refs.keys))
    }

    /// 注销全部热键并开始新的一代。绑定表被替换（编号重排）时调用。
    func beginNewGeneration() {
        unregisterAll()
        generation = CarbonHotkeyID.nextGeneration(after: generation)
    }

    /// 由 C 回调转入：代数相符且这个 id 仍已注册时通知上层，否则丢弃。
    fileprivate func fire(rawID: UInt32) {
        let (eventGeneration, id) = CarbonHotkeyID.decode(rawID)
        guard eventGeneration == generation, refs[id] != nil else {
            log.info("丢弃过期的热键事件（编号 \(id)，代数 \(eventGeneration)，当前代数 \(self.generation)）")
            return
        }
        onHotkey?(id)
    }

    // MARK: - 私有

    /// 在应用事件目标上安装 `kEventHotKeyPressed` 处理器，userData 指向本对象（不持有）。
    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), carbonHotkeyCallback, 1, &eventType,
                                         userData, &handlerRef)
        if status != noErr {
            log.error("安装热键事件处理器失败：\(status)")
        }
    }

    /// Core 修饰键到 Carbon 修饰键位的换算。
    static func carbonModifiers(_ modifiers: HotkeyModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    // 注册器与应用同生命周期，不实现 deinit：deinit 不在主 actor 上，不能安全地访问 refs 与 handlerRef。
}

/// Carbon 热键事件的 C 回调。取出 `EventHotKeyID`，签名相符时转给注册器。
private func carbonHotkeyCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == CarbonHotkeyRegistrar.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let id = hotKeyID.id
    // 指针不是 Sendable，按地址整数传进主 actor 的闭包，再还原。
    let address = Int(bitPattern: userData)
    // 应用事件目标的事件由主线程的事件循环分发，这里一定在主线程。
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(pointer).takeUnretainedValue()
        registrar.fire(rawID: id)
    }
    return noErr
}
