// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置的取值范围与一致性（架构文档 5.2 节）。只改正越界或不一致的值，
// 合法值原样保留，所以对默认配置是无操作，重复调用结果不变。

import Foundation

/// 配置校验：把越界值夹回范围，修复结构上的不一致。
public enum ConfigValidator {
    /// 缩略图尺寸每一维的绝对范围，单位是点。下限与「屏幕上至少可见 32 点」一致。
    public static let sizeLimit: ClosedRange<Double> = 32...4096
    /// 配置方案名称的最大长度（按字符计，去掉首尾空白后）。
    public static let maxProfileNameLength = 64
    /// 名称为空时使用的配置方案名称。
    public static let fallbackProfileName = "Profile"
    /// 布局坐标与登录位置每个分量的范围，单位是点。远超任何显示器排列，只用来挡住极端值：
    /// 过大的值在设置窗口里转整数显示时会越界，参与吸附与夹取计算时也会失去精度。
    public static let coordinateLimit: ClosedRange<Double> = -100_000...100_000

    /// 把越界值夹回范围，保证至少 1 个配置方案、activeProfileID 有效、id 与名称唯一。
    ///
    /// 改正规则：
    /// - 数值越界夹到最近的边界；NaN、无穷大改回默认值。
    /// - 尺寸每一维夹到 `sizeLimit`，最大尺寸不小于最小尺寸，默认尺寸夹到两者之间。
    /// - 非法颜色改回默认颜色；按角色设置的非法颜色被删除。
    /// - 布局里非有限的坐标改为 0，非正或非有限的宽高改为 nil；坐标与登录位置夹到 `coordinateLimit`。
    /// - 循环组成员去掉重复项，保留第一次出现的位置（架构文档 5.4 节）。
    /// - 战斗提醒的持续时间、最小伤害夹到范围内，非法颜色改回默认值；
    ///   `eveLogDirectory` 去掉首尾空白后是空串时改成 nil（反馈文档 3.2 节）。
    /// - `general.logLevel` 不是 info 或 debug 时改成 info（v1.1 设计 3.1 节）。
    /// - 预警与翻译：数值夹到范围内，频道去重与截断，空的参考星系改成 nil，不可用的浮窗 frame 改成 nil，
    ///   接口地址与模型名去掉首尾空白（docs/macos/design-intel-translate.md 3.2 节）。
    /// - 配置方案的 id 为空或重复时换新 UUID；名称去掉首尾空白，为空时用 `Profile`，
    ///   超长时截断，不区分大小写重名时追加 ` 2`、` 3` 等序号。循环组 id 同理。
    /// - 没有配置方案时补一个 `Default`；activeProfileID 无效时取第一个配置方案。
    ///
    /// - Returns: 改正后的配置，以及被改正字段的路径（如 `profiles[0].thumbnail.opacity`）。
    public static func normalized(_ config: AppConfig) -> (config: AppConfig, clamped: [String]) {
        var fixer = FieldFixer()
        var result = config

        if result.schemaVersion != ConfigMigrator.currentSchemaVersion {
            result.schemaVersion = ConfigMigrator.currentSchemaVersion
            fixer.record("schemaVersion")
        }
        fixer.clamp(&result.general.pollIntervalMs, to: 300...2000, path: "general.pollIntervalMs")
        // 只把空白串改成 nil；非空的路径原样保留（含首尾空白），由跟踪服务按候选规则解释。
        if let directory = result.general.eveLogDirectory,
           directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.general.eveLogDirectory = nil
            fixer.record("general.eveLogDirectory")
        }
        // 文件日志只提供 info 与 debug 两档（v1.1 设计 3.1 节）；手工改成别的级别时改回 info。
        // autoInstallUpdates 与 checkForUpdates 的组合不在这里改，界面按「不检查」处理。
        if result.general.logLevel != .info && result.general.logLevel != .debug {
            result.general.logLevel = .info
            fixer.record("general.logLevel")
        }
        normalizeEndpoint(&result.general.translationEndpoint, path: "general.translationEndpoint", fixer: &fixer)

        if result.profiles.isEmpty {
            result.profiles = [Profile.makeNew(name: Profile.defaultName)]
            fixer.record("profiles")
        }
        var seenIDs = Set<String>()
        var seenNames: [String] = []
        for index in result.profiles.indices {
            let path = "profiles[\(index)]"
            normalizeIdentity(of: &result.profiles[index], path: path,
                              seenIDs: &seenIDs, seenNames: &seenNames, fixer: &fixer)
            normalizeSettings(of: &result.profiles[index], path: path, fixer: &fixer)
        }

        if !result.profiles.contains(where: { $0.id == result.activeProfileID }) {
            result.activeProfileID = result.profiles[0].id
            fixer.record("activeProfileID")
        }
        return (result, fixer.paths)
    }

    // MARK: - 配置方案的身份

    /// 改正配置方案的 id 与名称，保证在整个配置内唯一。
    private static func normalizeIdentity(of profile: inout Profile, path: String,
                                          seenIDs: inout Set<String>, seenNames: inout [String],
                                          fixer: inout FieldFixer) {
        if profile.id.isEmpty || seenIDs.contains(profile.id) {
            profile.id = UUID().uuidString
            fixer.record("\(path).id")
        }
        seenIDs.insert(profile.id)

        let name = uniqueName(base: profile.name, taken: seenNames)
        if name != profile.name {
            profile.name = name
            fixer.record("\(path).name")
        }
        seenNames.append(name)
    }

    /// 生成一个合法且不与 taken 重名（不区分大小写）的名称。
    static func uniqueName(base: String, taken: [String]) -> String {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = fallbackProfileName }
        // 截断后再去一次首尾空白：截断点落在空白上时，结果末尾会留下空白，下次校验又会被去掉，
        // 那样同一份配置校验两次结果不同。
        trimmed = String(trimmed.prefix(maxProfileNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        func isTaken(_ candidate: String) -> Bool {
            taken.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
        }
        guard isTaken(trimmed) else { return trimmed }
        var number = 2
        while true {
            let suffix = " \(number)"
            // 加序号后仍不超过长度上限：先截短基名，再拼序号。
            let stem = String(trimmed.prefix(maxProfileNameLength - suffix.count))
                .trimmingCharacters(in: .whitespaces)
            let candidate = stem + suffix
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    // MARK: - 配置方案的设置

    /// 改正一个配置方案内的全部取值。
    private static func normalizeSettings(of profile: inout Profile, path: String, fixer: inout FieldFixer) {
        normalizeThumbnail(&profile.thumbnail, path: "\(path).thumbnail", fixer: &fixer)
        normalizeOverlay(&profile.overlay, path: "\(path).overlay", fixer: &fixer)
        normalizeCombatAlert(&profile.combatAlert, path: "\(path).combatAlert", fixer: &fixer)
        normalizeIntel(&profile.intel, path: "\(path).intel", fixer: &fixer)
        normalizeTranslation(&profile.translation, path: "\(path).translation", fixer: &fixer)

        let behaviorPath = "\(path).behavior.hideDelaySeconds"
        fixer.clamp(&profile.behavior.hideDelaySeconds, to: 0...10, default: 1.0, path: behaviorPath)
        fixer.clamp(&profile.capture.frameRate, to: 1...60, path: "\(path).capture.frameRate")
        fixer.clamp(&profile.capture.titleBarCropHeight, to: 0...60, default: 28,
                    path: "\(path).capture.titleBarCropHeight")

        if !profile.loginPosition.x.isFinite || !profile.loginPosition.y.isFinite {
            profile.loginPosition = Profile.defaultLoginPosition
            fixer.record("\(path).loginPosition")
        }
        // 两个分量此时都是有限值，fallback 不会用到，只为满足 clamp 的参数。
        let login = Profile.defaultLoginPosition
        fixer.clamp(&profile.loginPosition.x, to: coordinateLimit, default: login.x, path: "\(path).loginPosition")
        fixer.clamp(&profile.loginPosition.y, to: coordinateLimit, default: login.y, path: "\(path).loginPosition")
        normalizeLayouts(&profile.layouts, path: "\(path).layouts", fixer: &fixer)
        // 按角色的高亮颜色：非法值直接删除，回退到全局高亮颜色。
        // 按名字排序遍历，使 clamped 里的路径顺序每次相同（字典的遍历顺序不固定）。
        for name in profile.highlightColors.keys.sorted()
        where HexColor.components(profile.highlightColors[name] ?? "") == nil {
            profile.highlightColors[name] = nil
            fixer.record("\(path).highlightColors[\(name)]")
        }
        var groupIDs = Set<String>()
        for index in profile.cycleGroups.indices {
            let id = profile.cycleGroups[index].id
            if id.isEmpty || groupIDs.contains(id) {
                profile.cycleGroups[index].id = UUID().uuidString
                fixer.record("\(path).cycleGroups[\(index)].id")
            }
            groupIDs.insert(profile.cycleGroups[index].id)
            removeDuplicateMembers(&profile.cycleGroups[index].members,
                                   path: "\(path).cycleGroups[\(index)].members", fixer: &fixer)
        }
    }

    /// 去掉循环组成员里的重复项，保留第一次出现的位置（架构文档 5.4 节）。
    /// 重复成员会让循环停在前几个成员之间（引擎按角色名定位起点，总取第一次出现），所以在这里去掉。
    private static func removeDuplicateMembers(_ members: inout [String], path: String, fixer: inout FieldFixer) {
        var seen = Set<String>()
        let unique = members.filter { seen.insert($0).inserted }
        if unique.count != members.count {
            members = unique
            fixer.record(path)
        }
    }

    /// 改正缩略图设置：尺寸关系、透明度与放大倍数。
    private static func normalizeThumbnail(_ t: inout ThumbnailSettings, path: String, fixer: inout FieldFixer) {
        let d = ThumbnailSettings()
        fixer.clamp(&t.minimumSize, to: sizeLimit, default: d.minimumSize, path: "\(path).minimumSize")
        fixer.clamp(&t.maximumSize, to: sizeLimit, default: d.maximumSize, path: "\(path).maximumSize")
        // 最大尺寸不小于最小尺寸；两者冲突时以最小尺寸为准。
        fixer.clamp(&t.maximumSize.width, to: t.minimumSize.width...sizeLimit.upperBound,
                    default: d.maximumSize.width, path: "\(path).maximumSize.width")
        fixer.clamp(&t.maximumSize.height, to: t.minimumSize.height...sizeLimit.upperBound,
                    default: d.maximumSize.height, path: "\(path).maximumSize.height")
        fixer.clamp(&t.defaultSize.width, to: t.minimumSize.width...t.maximumSize.width,
                    default: d.defaultSize.width, path: "\(path).defaultSize.width")
        fixer.clamp(&t.defaultSize.height, to: t.minimumSize.height...t.maximumSize.height,
                    default: d.defaultSize.height, path: "\(path).defaultSize.height")
        fixer.clamp(&t.opacity, to: 0.2...1.0, default: d.opacity, path: "\(path).opacity")
        fixer.clamp(&t.zoomFactor, to: 2...10, path: "\(path).zoomFactor")
    }

    /// 改正叠层设置：字号、高亮与中性边框的粗细和颜色。
    private static func normalizeOverlay(_ o: inout OverlaySettings, path: String, fixer: inout FieldFixer) {
        let d = OverlaySettings()
        fixer.clamp(&o.titleFontSize, to: 8...36, default: d.titleFontSize, path: "\(path).titleFontSize")
        fixer.clamp(&o.highlightThickness, to: 1...6, path: "\(path).highlightThickness")
        fixer.clamp(&o.borderThickness, to: 1...6, path: "\(path).borderThickness")
        fixer.requireHexColor(&o.borderColor, default: d.borderColor, path: "\(path).borderColor")
        if HexColor.components(o.titleColor) == nil {
            o.titleColor = d.titleColor
            fixer.record("\(path).titleColor")
        }
        if HexColor.components(o.highlightColor) == nil {
            o.highlightColor = d.highlightColor
            fixer.record("\(path).highlightColor")
        }
    }

    /// 改正战斗提醒设置：持续时间、最小伤害与颜色（反馈文档 3.2 节）。
    private static func normalizeCombatAlert(_ a: inout CombatAlertSettings, path: String,
                                             fixer: inout FieldFixer) {
        let d = CombatAlertSettings()
        fixer.clamp(&a.durationSeconds, to: CombatAlertSettings.durationRange, default: d.durationSeconds,
                    path: "\(path).durationSeconds")
        fixer.clamp(&a.minimumDamage, to: CombatAlertSettings.minimumDamageRange, path: "\(path).minimumDamage")
        fixer.requireHexColor(&a.color, default: d.color, path: "\(path).color")
    }

    // MARK: - 预警与翻译（docs/macos/design-intel-translate.md 3.2 节）

    /// 改正预警设置：3 个整数夹到范围内（先夹 maxJumps，再让 alertJumps 不超过它），频道、参考星系与浮窗。
    private static func normalizeIntel(_ intel: inout IntelSettings, path: String, fixer: inout FieldFixer) {
        fixer.clamp(&intel.windowMinutes, to: IntelSettings.windowMinutesRange, path: "\(path).windowMinutes")
        fixer.clamp(&intel.maxJumps, to: IntelSettings.maxJumpsRange, path: "\(path).maxJumps")
        fixer.clamp(&intel.alertJumps, to: IntelSettings.alertJumpsRange, path: "\(path).alertJumps")
        // 第 2 条：高亮距离不超过计算上限。
        if intel.alertJumps > intel.maxJumps {
            intel.alertJumps = intel.maxJumps
            fixer.record("\(path).alertJumps")
        }
        normalizeChannels(&intel.channels, path: "\(path).channels", fixer: &fixer)
        // 第 5 条：只把空白串改成 nil；名称是否存在由预警功能在使用时按星图数据判断。
        if let reference = intel.referenceSystem,
           reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            intel.referenceSystem = nil
            fixer.record("\(path).referenceSystem")
        }
        normalizeOverlayPanel(&intel.overlay, path: "\(path).overlay", fixer: &fixer)
    }

    /// 改正翻译设置：频道与浮窗。目标语言已在解码时由宽松解码兜底。
    private static func normalizeTranslation(_ translation: inout TranslationSettings, path: String,
                                             fixer: inout FieldFixer) {
        normalizeChannels(&translation.channels, path: "\(path).channels", fixer: &fixer)
        normalizeOverlayPanel(&translation.overlay, path: "\(path).overlay", fixer: &fixer)
    }

    /// 改正频道列表（第 3、4 条）：名字去掉首尾空白；空白的 id 改成 nil；名字与 id 都空的项、私聊频道的项删除；
    /// 按「id 相同，或都没有 id 且名字不区分大小写相同」去重，保留靠前的一项；超过 16 项时保留前 16 项。
    private static func normalizeChannels(_ channels: inout [ChannelRef], path: String, fixer: inout FieldFixer) {
        var result: [ChannelRef] = []
        for var channel in channels {
            channel.name = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = channel.id, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                channel.id = nil
            }
            if channel.name.isEmpty && channel.id == nil { continue }
            if let id = channel.id, id.lowercased().hasPrefix("private_") { continue }
            let duplicate = result.contains { kept in
                if let id = channel.id { return kept.id == id }
                return kept.id == nil && kept.name.caseInsensitiveCompare(channel.name) == .orderedSame
            }
            if !duplicate { result.append(channel) }
        }
        if result.count > IntelSettings.maxChannels {
            result = Array(result.prefix(IntelSettings.maxChannels))
        }
        if result != channels {
            channels = result
            fixer.record(path)
        }
    }

    /// 改正浮窗设置（第 1、6 条）：不透明度与字号夹到范围内，非有限值改回默认值；
    /// frame 的宽或高不是有限的正数、或坐标不是有限值时整个改成 nil。尺寸与屏幕范围的收拢在 OverlayPlanner 里做。
    private static func normalizeOverlayPanel(_ overlay: inout OverlayPanelSettings, path: String,
                                              fixer: inout FieldFixer) {
        let d = OverlayPanelSettings()
        fixer.clamp(&overlay.opacity, to: OverlayPanelSettings.opacityRange, default: d.opacity,
                    path: "\(path).opacity")
        fixer.clamp(&overlay.fontSize, to: OverlayPanelSettings.fontSizeRange, default: d.fontSize,
                    path: "\(path).fontSize")
        if let frame = overlay.frame {
            let usable = frame.width.isFinite && frame.width > 0 && frame.height.isFinite && frame.height > 0
                && frame.x.isFinite && frame.y.isFinite
            if !usable {
                overlay.frame = nil
                fixer.record("\(path).frame")
            }
        }
    }

    /// 改正模型服务的设置（第 7 条）：地址与模型名去掉首尾空白，地址末尾的 `/` 全部去掉。
    /// 地址是否可用由 TranslationProviders.resolve 在使用时判断，这里不改。
    private static func normalizeEndpoint(_ endpoint: inout TranslationEndpointSettings, path: String,
                                          fixer: inout FieldFixer) {
        var baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        if baseURL != endpoint.baseURL {
            endpoint.baseURL = baseURL
            fixer.record("\(path).baseURL")
        }
        let model = endpoint.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if model != endpoint.model {
            endpoint.model = model
            fixer.record("\(path).model")
        }
    }

    /// 改正布局记录里无法使用的数值。尺寸范围由 `LayoutResolver.clampSize` 在使用时夹取，这里不改。
    private static func normalizeLayouts(_ layouts: inout [String: ThumbnailLayout], path: String,
                                         fixer: inout FieldFixer) {
        for name in layouts.keys.sorted() {
            guard var layout = layouts[name] else { continue }
            let original = layout
            // 非有限值改为 0，再把坐标夹到 coordinateLimit；0 本身在范围内，所以再调一次不变。
            layout.x = layout.x.isFinite ? min(max(layout.x, coordinateLimit.lowerBound), coordinateLimit.upperBound) : 0
            layout.y = layout.y.isFinite ? min(max(layout.y, coordinateLimit.lowerBound), coordinateLimit.upperBound) : 0
            if let w = layout.width, !(w.isFinite && w > 0) { layout.width = nil }
            if let h = layout.height, !(h.isFinite && h > 0) { layout.height = nil }
            if layout != original {
                layouts[name] = layout
                fixer.record("\(path)[\(name)]")
            }
        }
    }
}

/// 收集被改正字段路径的辅助类型。
private struct FieldFixer {
    /// 被改正字段的路径，按改正顺序，不重复。
    private(set) var paths: [String] = []

    /// 记下一个被改正的字段。
    mutating func record(_ path: String) {
        if !paths.contains(path) { paths.append(path) }
    }

    /// 把整数夹到范围内。
    mutating func clamp(_ value: inout Int, to range: ClosedRange<Int>, path: String) {
        let fixed = min(max(value, range.lowerBound), range.upperBound)
        if fixed != value {
            value = fixed
            record(path)
        }
    }

    /// 把浮点数夹到范围内；NaN 或无穷大先改为 fallback，fallback 同样夹到范围内，保证再调一次不变。
    mutating func clamp(_ value: inout Double, to range: ClosedRange<Double>, default fallback: Double,
                        path: String) {
        let source = value.isFinite ? value : fallback
        let fixed = min(max(source, range.lowerBound), range.upperBound)
        if fixed != value || value.isNaN {
            value = fixed
            record(path)
        }
    }

    /// 颜色不是合法的 `#RRGGBB` 时改回 fallback。
    mutating func requireHexColor(_ value: inout String, default fallback: String, path: String) {
        guard HexColor.components(value) == nil else { return }
        value = fallback
        record(path)
    }

    /// 把尺寸的每一维夹到范围内。
    mutating func clamp(_ size: inout ScreenSize, to range: ClosedRange<Double>, default fallback: ScreenSize,
                        path: String) {
        clamp(&size.width, to: range, default: fallback.width, path: "\(path).width")
        clamp(&size.height, to: range, default: fallback.height, path: "\(path).height")
    }
}
