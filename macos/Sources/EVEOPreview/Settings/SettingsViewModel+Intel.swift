// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口视图模型的「预警」页部分（docs/macos/design-intel-translate.md 第 10 节）：预警设置的绑定、状态行的文字、
// 各角色位置的读取与手动设置、参考星系、星图数据的版本，以及 6.9 节增补的人名核对状态与人名缓存。
// 位置、核对状态与缓存条数来自 coordinator.chat.intel 的只读属性，不是本视图模型的存储属性；
// 页面在 body 里读 chatRevision，这些值变化时随之重绘。

import AppKit
import SwiftUI
import EVEOPreviewCore

extension SettingsViewModel {
    /// 预警功能的控制器。
    private var intelFeed: IntelFeedController { coordinator.chat.intel }

    /// 当前配置方案的预警设置某个字段的绑定。
    func intelBinding<Value>(_ keyPath: WritableKeyPath<IntelSettings, Value>) -> Binding<Value> {
        let base: WritableKeyPath<Profile, IntelSettings> = \.intel
        return binding(base.appending(path: keyPath))
    }

    /// 聊天日志的状态文字（两个页共用 L10n.settings 里的 5 条）。
    var intelStatusText: String {
        let strings = L10n.settings
        switch chatLogStatus {
        case .stopped: return strings.chatLogStatusStopped
        case .watching(let directory, let files): return strings.chatLogStatusWatching(directory: directory, files: files)
        case .directoryNotFound(let path): return strings.chatLogStatusDirectoryNotFound(path)
        case .accessDenied(let path): return strings.chatLogStatusAccessDenied(path)
        }
    }

    /// 聊天日志的状态是否为「没有访问权限」。
    var chatLogAccessDenied: Bool {
        if case .accessDenied = chatLogStatus { return true }
        return false
    }

    /// 「我的位置」列出的角色：在线的角色，按名称排序。
    var intelCharacters: [String] {
        onlineCharacters.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 某个角色的位置文字：星系（来源，多久以前），没有记录时是「未知」。
    func intelLocationText(for character: String) -> String {
        let strings = L10n.intel
        guard let location = CharacterNameMatch.value(for: character, in: intelFeed.locations) else {
            return strings.locationUnknown
        }
        let language = L10n.language
        let system = coordinator.chat.staticData?.system(id: location.systemID)?.name(in: language)
            ?? String(location.systemID)
        let seconds = IntelFeedController.wholeSeconds(Date().timeIntervalSince1970 - location.time)
        return strings.locationValue(system: system, source: IntelFeedController.sourceText(location.source),
                                     age: IntelLineFormatter().age(seconds: seconds))
    }

    /// 某个角色有没有位置记录（「清除」按钮只在有记录时可用）。
    func hasIntelLocation(_ character: String) -> Bool {
        CharacterNameMatch.value(for: character, in: intelFeed.locations) != nil
    }

    /// 手动设置某个角色的位置；星系名查不到时返回假。空输入不做任何事，返回真。
    @discardableResult
    func setIntelLocation(character: String, systemName: String) -> Bool {
        let name = systemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return true }
        return intelFeed.setManualLocation(character: character, systemName: name)
    }

    /// 清除某个角色的位置记录。
    func clearIntelLocation(character: String) {
        intelFeed.clearManualLocation(character: character)
    }

    /// 参考星系的文字（没有时为空串）。
    var referenceSystemText: String { profile.intel.referenceSystem ?? "" }

    /// 提交参考星系：去掉首尾空白，空串改成 nil。
    func commitReferenceSystem(_ text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updateProfile { $0.intel.referenceSystem = name.isEmpty ? nil : name }
    }

    /// 参考星系填了、星图数据已读入、却查不到时为真（输入框下显示「找不到这个星系」）。
    var referenceSystemNotFound: Bool {
        guard let name = profile.intel.referenceSystem, let data = coordinator.chat.staticData else { return false }
        return data.system(named: name) == nil
    }

    /// 星图数据一行的文字：SDE 版本、缺失或无效时的说明；还没读时是「—」。
    var staticDataText: String {
        if staticDataState.hasPrefix("build-"), let build = Int(staticDataState.dropFirst("build-".count)) {
            return L10n.intel.staticDataBuild(build)
        }
        if staticDataState == "missing" || staticDataState == "invalid" { return L10n.intel.staticDataMissing }
        return "—"
    }

    // MARK: - 人名核对（6.9 节增补）

    /// 人名核对的状态文字；状态是 off 时为 nil（开关关着，或预警没开）。等待的时刻已过时显示成就绪。
    var pilotLookupStatusText: String? {
        let strings = L10n.intel
        switch intelFeed.pilotLookupStatus {
        case .off:
            return nil
        case .idle:
            return strings.pilotLookupIdle(intelFeed.pilotCacheCount)
        case .resolving:
            return strings.pilotLookupResolving
        case .waiting(let until):
            let seconds = Int((until - Date().timeIntervalSince1970).rounded(.up))
            return seconds > 0 ? strings.pilotLookupWaiting(seconds) : strings.pilotLookupIdle(intelFeed.pilotCacheCount)
        }
    }

    /// 人名缓存一行的条数文字；缓存文件还没读时为 nil（预警第一次启用时才读）。
    var pilotCacheText: String? {
        intelFeed.isPilotCacheLoaded ? L10n.intel.pilotCacheCount(intelFeed.pilotCacheCount) : nil
    }

    /// 清空内存与文件里的人名缓存。
    func clearPilotCache() {
        intelFeed.clearPilotCache()
    }
}
