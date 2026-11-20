// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置的持有者（架构文档 5.2 节、7.2 节）：读入配置、接受修改、延迟写盘、通知变化。
//
// - 每次修改后经 ConfigValidator 校验，再通知观察者，最后安排 0.5 秒后写盘；连续修改合并成一次写盘。
// - 退出前调用 flush() 立即写盘。
// - 读配置失败（文件来自更新的版本，或读文件出错）时用默认配置运行，本次会话不写盘，
//   避免用默认值覆盖用户的文件。设置窗口据 loadError 显示提示。

import Foundation
import EVEOPreviewCore
import os

/// 配置的持有者。全部方法在主线程调用。
@MainActor
final class ConfigController {
    /// 配置变化的回调，参数是变化前与变化后的配置。
    typealias Observer = @MainActor (_ old: AppConfig, _ new: AppConfig) -> Void

    /// 当前配置，总是经过 `ConfigValidator.normalized`。
    private(set) var config: AppConfig
    /// 读配置时的警告，供设置窗口提示。
    private(set) var warnings: [ConfigWarning]
    /// 读配置失败的原因；非 nil 时本次会话不写盘。
    let loadError: ConfigError?
    /// 配置文件的位置。
    var fileURL: URL { store.fileURL }
    /// 是否允许写盘。
    var isWritable: Bool { loadError == nil }

    private let store: any ConfigStore
    private var observers: [Observer] = []
    private var pendingSave: Task<Void, Never>?
    private let log = AppLog.logger("Config")

    /// 写盘的延迟，单位是秒。
    static let saveDelay: Duration = .milliseconds(500)

    /// 从存储读入配置。读失败时用默认配置，并记下原因。
    init(store: any ConfigStore) {
        self.store = store
        do {
            let result = try store.load()
            config = result.config
            warnings = result.warnings
            loadError = nil
        } catch {
            // 默认配置也要经过校验，保证与正常路径的配置形态一致。
            config = ConfigValidator.normalized(AppConfig.makeDefault()).config
            warnings = []
            loadError = error
            log.error("读配置失败，本次会话不写盘：\(String(describing: error), privacy: .public)")
        }
    }

    /// 注册变化回调。回调在每次 `update` 改变了配置后调用，按注册顺序。
    func addObserver(_ observer: @escaping Observer) {
        observers.append(observer)
    }

    /// 修改配置。修改后校验、通知观察者并安排写盘；内容没变时什么也不做。
    func update(_ body: (inout AppConfig) -> Void) {
        var draft = config
        body(&draft)
        let normalized = ConfigValidator.normalized(draft)
        guard normalized.config != config else { return }
        if !normalized.clamped.isEmpty {
            // 字段路径里可能有角色名（如 layouts[角色名]），按 .private 记录。
            log.debug("修改后有字段被夹回范围：\(normalized.clamped.joined(separator: ", "), privacy: .private)")
        }
        let old = config
        config = normalized.config
        for observer in observers {
            observer(old, config)
        }
        scheduleSave()
    }

    /// 修改当前配置方案，是 `update` 的简写。
    func updateActiveProfile(_ body: (inout Profile) -> Void) {
        update { $0.updateActiveProfile(body) }
    }

    /// 立即写盘，取消等待中的延迟写盘。退出前调用。
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    /// 安排一次延迟写盘；已有等待中的写盘时先取消它，使连续修改只写一次。
    private func scheduleSave() {
        guard isWritable else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: ConfigController.saveDelay)
            guard !Task.isCancelled else { return }
            self?.pendingSave = nil
            self?.save()
        }
    }

    /// 写盘。失败只记日志：下一次修改会再试。
    private func save() {
        guard isWritable else { return }
        do {
            try store.save(config)
            log.debug("配置已保存")
        } catch {
            log.error("写配置失败：\(String(describing: error), privacy: .public)")
        }
    }
}
