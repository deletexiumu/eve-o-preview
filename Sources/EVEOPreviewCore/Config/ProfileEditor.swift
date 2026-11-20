// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置方案的新建、克隆、改名、删除（架构文档 5.2 节）。
// 都是纯函数：成功时返回改好的新配置，操作不合法时返回 nil，原配置不变。

import Foundation

/// 配置方案的增删改。名称规则：去掉首尾空白后 1～64 字，不区分大小写唯一。
public enum ProfileEditor {
    /// 名称是否可用。
    ///
    /// - Parameters:
    ///   - name: 候选名称，比较前去掉首尾空白。
    ///   - config: 现有配置。
    ///   - id: 比较时排除的配置方案 id（改名时传被改名的方案，使「改回原名」合法）；nil 表示不排除。
    public static func isValidName(_ name: String, in config: AppConfig, excluding id: String?) -> Bool {
        let candidate = trimmed(name)
        guard (1...ConfigValidator.maxProfileNameLength).contains(candidate.count) else { return false }
        return !config.profiles.contains { profile in
            profile.id != id && trimmed(profile.name).caseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    /// 新建一个全部取默认值的配置方案，追加到末尾，不切换当前方案。名称非法时返回 nil。
    public static func add(named name: String, to config: AppConfig) -> AppConfig? {
        guard isValidName(name, in: config, excluding: nil) else { return nil }
        var result = config
        result.profiles.append(Profile(name: trimmed(name)))
        return result
    }

    /// 复制一个配置方案，内容相同、id 与名称不同，插在原方案之后，不切换当前方案。
    ///
    /// 源方案不存在或名称非法时返回 nil。
    public static func clone(id: String, newName: String, in config: AppConfig) -> AppConfig? {
        guard let index = config.profiles.firstIndex(where: { $0.id == id }),
              isValidName(newName, in: config, excluding: nil) else { return nil }
        var copy = config.profiles[index]
        copy.id = UUID().uuidString
        copy.name = trimmed(newName)
        var result = config
        result.profiles.insert(copy, at: index + 1)
        return result
    }

    /// 给配置方案改名。方案不存在或名称非法时返回 nil；新名称与自己的旧名称只差大小写时合法。
    public static func rename(id: String, to name: String, in config: AppConfig) -> AppConfig? {
        guard let index = config.profiles.firstIndex(where: { $0.id == id }),
              isValidName(name, in: config, excluding: id) else { return nil }
        var result = config
        result.profiles[index].name = trimmed(name)
        return result
    }

    /// 删除配置方案。最后一个不能删，方案不存在时也返回 nil。
    ///
    /// 删除的是当前方案时，当前方案改为删除位置上的下一个方案；删的是末尾的方案时改为新的末尾。
    public static func delete(id: String, in config: AppConfig) -> AppConfig? {
        guard config.profiles.count > 1,
              let index = config.profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var result = config
        result.profiles.remove(at: index)
        if config.activeProfileID == id {
            result.activeProfileID = result.profiles[min(index, result.profiles.count - 1)].id
        }
        return result
    }

    /// 去掉首尾空白与换行。
    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
