// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口视图模型的动作：配置方案的增删改、循环组的编辑、热键的读写与问题提示、权限。
// 热键在配置里是带可选作用范围后缀的字符串（反馈文档 6.1 节），读写一律经 HotkeySpec，
// 不直接用 Hotkey(string:)：后者不认 `@game` 后缀，会把合法的热键显示成「无法识别」。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 一个热键列表在配置里的位置。热键在配置里是字符串数组，一个动作可以绑定多个组合。
enum HotkeySlot: Hashable {
    case toggleHideAll, minimizeAll, cycleLoginClients
    case cycleForward(groupID: String), cycleBackward(groupID: String)
    case character(String)

    /// 这个位置对应的热键动作，用来在热键规划里查问题。
    var action: HotkeyAction {
        switch self {
        case .toggleHideAll: return .toggleHideAll
        case .minimizeAll: return .minimizeAll
        case .cycleLoginClients: return .cycleLoginClients
        case .cycleForward(let id): return .cycle(groupID: id, direction: .forward)
        case .cycleBackward(let id): return .cycle(groupID: id, direction: .backward)
        case .character(let name): return .activateCharacter(name)
        }
    }
}

// MARK: - 配置方案

extension SettingsViewModel {
    /// 名称是否可用于新建、克隆（excluding 为 nil）或改名（excluding 为被改名的方案）。
    func isValidProfileName(_ name: String, excluding id: String?) -> Bool {
        ProfileEditor.isValidName(name, in: config, excluding: id)
    }

    /// 切换当前配置方案。
    func switchProfile(_ id: String) {
        coordinator.switchProfile(to: id)
    }

    /// 新建配置方案，成功时返回 true。
    @discardableResult
    func addProfile(named name: String) -> Bool {
        apply(ProfileEditor.add(named: name, to: config))
    }

    /// 克隆配置方案，成功时返回 true。
    @discardableResult
    func cloneProfile(_ id: String, as name: String) -> Bool {
        apply(ProfileEditor.clone(id: id, newName: name, in: config))
    }

    /// 给配置方案改名，成功时返回 true。
    @discardableResult
    func renameProfile(_ id: String, to name: String) -> Bool {
        apply(ProfileEditor.rename(id: id, to: name, in: config))
    }

    /// 删除配置方案（最后一个不能删），成功时返回 true。
    @discardableResult
    func deleteProfile(_ id: String) -> Bool {
        apply(ProfileEditor.delete(id: id, in: config))
    }

    /// 把 ProfileEditor 的结果写回配置；结果为 nil（操作不合法）时什么也不做。
    private func apply(_ edited: AppConfig?) -> Bool {
        guard let edited else { return false }
        coordinator.config.update { $0 = edited }
        return true
    }

    /// 在访达中显示配置文件；文件还没写过时打开所在目录。
    func revealConfigFile() {
        let url = configFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

// MARK: - 循环组

extension SettingsViewModel {
    /// 新建一个空的循环组，名称按序号生成。
    func addCycleGroup() {
        let name = L10n.hotkeys.newGroupName(profile.cycleGroups.count + 1)
        updateProfile { $0.cycleGroups.append(CycleGroup(name: name)) }
    }

    /// 删除循环组。
    func deleteCycleGroup(_ id: String) {
        updateProfile { $0.cycleGroups.removeAll { $0.id == id } }
    }

    /// 修改循环组。找不到时什么也不做。
    func updateCycleGroup(_ id: String, _ body: (inout CycleGroup) -> Void) {
        updateProfile { profile in
            if let index = profile.cycleGroups.firstIndex(where: { $0.id == id }) {
                body(&profile.cycleGroups[index])
            }
        }
    }

    /// 把成员上移（offset 为 -1）或下移（offset 为 1）一位。
    func moveMember(in groupID: String, at index: Int, by offset: Int) {
        updateCycleGroup(groupID) { group in
            let target = index + offset
            guard group.members.indices.contains(index), group.members.indices.contains(target) else { return }
            group.members.swapAt(index, target)
        }
    }
}

// MARK: - 热键

extension SettingsViewModel {
    /// 某个位置当前的热键字符串。
    func hotkeys(for slot: HotkeySlot) -> [String] {
        let p = profile
        switch slot {
        case .toggleHideAll: return p.hotkeys.toggleHideAll
        case .minimizeAll: return p.hotkeys.minimizeAll
        case .cycleLoginClients: return p.hotkeys.cycleLoginClients
        case .cycleForward(let id): return p.cycleGroups.first { $0.id == id }?.forwardHotkeys ?? []
        case .cycleBackward(let id): return p.cycleGroups.first { $0.id == id }?.backwardHotkeys ?? []
        case .character(let name): return p.characterHotkeys[name] ?? []
        }
    }

    /// 写入某个位置的热键字符串。角色的列表为空时删掉这个键，避免配置里留空数组。
    func setHotkeys(_ list: [String], for slot: HotkeySlot) {
        switch slot {
        case .toggleHideAll: updateProfile { $0.hotkeys.toggleHideAll = list }
        case .minimizeAll: updateProfile { $0.hotkeys.minimizeAll = list }
        case .cycleLoginClients: updateProfile { $0.hotkeys.cycleLoginClients = list }
        case .cycleForward(let id): updateCycleGroup(id) { $0.forwardHotkeys = list }
        case .cycleBackward(let id): updateCycleGroup(id) { $0.backwardHotkeys = list }
        case .character(let name): updateProfile { $0.characterHotkeys[name] = list.isEmpty ? nil : list }
        }
    }

    /// 某条热键的问题说明：无法解析、与其他动作重复、被拒绝或不能生效；没有问题时为 nil。
    func hotkeyProblem(_ text: String, slot: HotkeySlot) -> String? {
        let action = slot.action
        guard let hotkey = HotkeySpec(string: text)?.hotkey else { return L10n.hotkeys.hotkeyUnparsable }
        for issue in hotkeyPlan.issues {
            switch issue {
            case .duplicate(let duplicated, let kept, let dropped) where duplicated == hotkey && dropped == action:
                return L10n.hotkeys.hotkeyDuplicate(describe(kept))
            case .rejected(let rejected, let owner, let reason) where rejected == hotkey && owner == action:
                return reason == .missingModifier ? L10n.hotkeys.hotkeyMissingModifier : L10n.hotkeys.hotkeyReserved
            default:
                continue
            }
        }
        if let failure = hotkeyFailures.first(where: { $0.binding.hotkey == hotkey && $0.binding.action == action }) {
            return failureText(failure.reason)
        }
        return nil
    }

    /// 不能生效的原因的提示文字（反馈文档 6.8 节）。
    private func failureText(_ reason: HotkeyFailureReason) -> String {
        switch reason {
        case .registrationRejected(let status): return L10n.hotkeys.hotkeyRegistrationFailed(status)
        case .accessibilityRequired: return L10n.hotkeys.hotkeyAccessibilityRequired
        case .eventTapUnavailable: return L10n.hotkeys.hotkeyEventTapUnavailable
        }
    }

    /// 作用范围的界面名称。
    func scopeName(_ scope: HotkeyScope) -> String {
        switch scope {
        case .global: return L10n.hotkeys.scopeGlobal
        case .game: return L10n.hotkeys.scopeGame
        }
    }

    /// 把一条热键的作用范围改成 scope（nil 表示去掉后缀、跟随默认）。
    /// 按文字在当前列表里找这一条；已不在列表里或解析不了时什么也不做。
    func setHotkeyScope(_ scope: HotkeyScope?, of text: String, for slot: HotkeySlot) {
        editHotkey(text, in: slot) { list, index in
            guard var spec = HotkeySpec(string: list[index]) else { return }
            spec.scope = scope
            list[index] = spec.stringValue()
        }
    }

    /// 改列表里的一条热键。提交的时刻才读当前列表，并按文字找到这一条，
    /// 不用视图建立时记下的列表与位置：录制期间别的行可能已被删除或改动，旧的列表会把删掉的行写回来。
    /// 这一条已不在列表里时什么也不做。同一列表里的热键文字不重复（添加时去重），文字就是这一行的标识。
    func editHotkey(_ text: String, in slot: HotkeySlot, _ change: (inout [String], Int) -> Void) {
        var list = hotkeys(for: slot)
        guard let index = list.firstIndex(of: text) else { return }
        change(&list, index)
        setHotkeys(list, for: slot)
    }

    /// 录到一个热键后要写进配置的字符串（反馈文档 6.8 节）。
    ///
    /// - 重新录制已有的一行（replacing 不为 nil）时保留这一行原来的作用范围。
    /// - 原来没有后缀（或是新添加的一行）而录到的是鼠标按键时，补上 `@game`：全局的鼠标绑定会在
    ///   所有应用里吞掉这个按键，例如浏览器的后退键会失效。
    /// - 录到的是键盘按键且原来没有后缀时，不写后缀。
    func recordedHotkeyText(_ hotkey: Hotkey, replacing old: String?) -> String {
        let oldScope = old.flatMap { HotkeySpec(string: $0)?.scope }
        let scope = oldScope ?? (hotkey.isMouse ? .game : nil)
        return HotkeySpec(hotkey: hotkey, scope: scope).stringValue()
    }

    /// 列表里是否已有这个热键。比较 Hotkey，不比较字符串：`F13` 与 `F13@game` 算同一个。
    func hotkeyList(_ list: [String], contains hotkey: Hotkey) -> Bool {
        list.contains { HotkeySpec(string: $0)?.hotkey == hotkey }
    }

    /// 热键动作的界面名称，用在「与某某重复」的提示里。
    func describe(_ action: HotkeyAction) -> String {
        switch action {
        case .toggleHideAll: return L10n.hotkeys.hotkeyToggleHideAll
        case .minimizeAll: return L10n.hotkeys.hotkeyMinimizeAll
        case .cycleLoginClients: return L10n.hotkeys.hotkeyCycleLogin
        case .activateCharacter(let name): return name
        case .cycle(let groupID, let direction):
            let name = profile.cycleGroups.first { $0.id == groupID }?.name ?? groupID
            return "\(name) · \(direction == .forward ? L10n.settings.forward : L10n.settings.backward)"
        }
    }

    /// 开始录制：第一个录制器开始时暂停全局热键，否则按下的组合会被自己的热键吞掉。
    func beginRecording() {
        recordingCount += 1
        if recordingCount == 1 { coordinator.services.hotkeys.suspend() }
    }

    /// 结束录制：最后一个录制器结束时恢复全局热键；恢复时注册失败的项经协调器显示在设置窗口里。
    func endRecording() {
        guard recordingCount > 0 else { return }
        recordingCount -= 1
        if recordingCount == 0 { coordinator.resumeHotkeys() }
    }
}

// MARK: - 权限

extension SettingsViewModel {
    /// 重新查询权限。权限页可见时每秒调用一次。
    func refreshPermissions() {
        coordinator.refreshPermissions()
        refreshRuntime()
    }

    /// 请求屏幕录制权限。
    func requestScreenRecording() {
        coordinator.services.permissions.requestScreenRecording()
        refreshPermissions()
    }

    /// 请求辅助功能权限（弹出系统提示）。
    func requestAccessibility() {
        coordinator.services.permissions.requestAccessibility()
        refreshPermissions()
    }

    /// 打开系统设置的对应面板。
    func openSystemSettings(_ pane: PermissionPane) {
        coordinator.services.permissions.openSystemSettings(pane)
    }

    /// 以新实例重新启动本应用（授权屏幕录制后通常需要）。
    func relaunch() {
        coordinator.config.flush()
        coordinator.services.permissions.relaunch()
    }
}
