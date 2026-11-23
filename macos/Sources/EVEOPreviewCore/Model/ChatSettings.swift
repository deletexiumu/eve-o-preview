// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与聊天翻译的设置（docs/design-intel-translate.md 3.1 节）。
// - IntelSettings、TranslationSettings 属于配置方案，JSON 路径是 profiles[].intel 与 profiles[].translation。
// - TranslationEndpointSettings 是全局设置，JSON 路径是 general.translationEndpoint。API Key 不在这里，存在钥匙串。
// - ChannelRef 同时存频道名与 Channel ID，匹配规则见 5.3 节。
// 全部结构的 init(from:) 用 decodeIfPresent，缺键取默认值；枚举键用 LenientDecoding。取值范围由 ConfigValidator 夹取。

import Foundation

/// 配置里的一个频道：用户看到的名字，加上可选的 Channel ID。
public struct ChannelRef: Sendable, Hashable, Codable {
    /// 用户看到的频道名（文件头的 Channel Name）。
    public var name: String
    /// 文件头的 Channel ID；nil 表示只按名字匹配。
    public var id: String?

    /// 用名字与可选的 ID 建一个频道。
    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }

    /// 本地频道（Local）。
    public static let local = ChannelRef(name: "Local", id: "local")
    /// 军团频道。
    public static let corp = ChannelRef(name: "Corp", id: "corp")
    /// 联盟频道。
    public static let alliance = ChannelRef(name: "Alliance", id: "alliance")
    /// 舰队频道；日志里的 ID 是 `fleet_<数字>`，按前缀匹配。
    public static let fleet = ChannelRef(name: "Fleet", id: "fleet")
    /// 4 个内置频道，按设置界面里的顺序。
    public static let builtIns: [ChannelRef] = [.local, .corp, .alliance, .fleet]

    /// 是否内置频道（id 是 local、corp、alliance、fleet 之一）。
    public var isBuiltIn: Bool {
        guard let id else { return false }
        return ChannelRef.builtInIDs.contains(id.lowercased())
    }

    /// 内置频道的 ID。
    static let builtInIDs: Set<String> = ["local", "corp", "alliance", "fleet"]

    /// 这个频道是否与日志文件头里的频道对应（5.3 节）：
    /// 1. 内置频道只看 ID：`fleet` 要求日志的 ID 以 `fleet_` 开头，其余要求 ID 相同（不区分大小写）。
    ///    不看名字，因为名字随客户端语言变。
    /// 2. 其他频道：`id` 有值且与日志的 ID 相同时匹配；否则名字去掉首尾空白后不区分大小写相同时匹配。
    /// 3. 日志的 ID 以 `private_` 开头时一律不匹配。
    public func matches(channelID: String?, channelName: String?) -> Bool {
        let logID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let logID, logID.lowercased().hasPrefix("private_") { return false }
        if isBuiltIn, let id {
            guard let logID else { return false }
            let own = id.lowercased()
            let other = logID.lowercased()
            return own == "fleet" ? other.hasPrefix("fleet_") : other == own
        }
        if let id, !id.isEmpty, let logID, id == logID { return true }
        let own = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty, let logName = channelName?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return own.caseInsensitiveCompare(logName) == .orderedSame
    }

    /// 解码时名字缺失为空串（由 ConfigValidator 去掉），ID 缺失为 nil。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        id = try c.decodeIfPresent(String.self, forKey: .id)
    }
}

/// 浮窗什么时候显示（v1.2.1，用户要求两个浮窗各自可选）。
public enum OverlayVisibility: String, Sendable, Codable, CaseIterable {
    /// 始终显示（默认）：只受「离开 EVE 时隐藏」这个与缩略图共用的开关与延迟约束，即升级前的行为。
    case always
    /// 仅游戏内：前台不是 EVE 客户端（也不是本应用）时立即隐藏，切回任一客户端时立即显示。
    case gameOnly
}

/// 一个浮窗的位置与外观（3.1 节的 overlay 对象）。
public struct OverlayPanelSettings: Sendable, Equatable, Codable {
    /// 背景不透明度的范围。
    public static let opacityRange: ClosedRange<Double> = 0.2...1.0
    /// 字号的范围，单位是点。
    public static let fontSizeRange: ClosedRange<Double> = 10...24

    /// 全局屏幕坐标的位置与尺寸；nil 表示用默认位置（8.6 节）。
    public var frame: ScreenRect?
    /// 背景的不透明度，默认 0.75，范围 0.2～1.0。文字始终不透明。
    public var opacity: Double
    /// 第一行的字号，单位是点，默认 12，范围 10～24。
    public var fontSize: Double
    /// 什么时候显示，默认始终显示。v1.2.1 新增。
    public var visibility: OverlayVisibility

    /// 用各字段建浮窗设置，默认值见各属性。
    public init(frame: ScreenRect? = nil, opacity: Double = 0.75, fontSize: Double = 12,
                visibility: OverlayVisibility = .always) {
        self.frame = frame
        self.opacity = opacity
        self.fontSize = fontSize
        self.visibility = visibility
    }

    /// 解码时缺失的键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverlayPanelSettings()
        frame = try c.decodeIfPresent(ScreenRect.self, forKey: .frame)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        // 不认识的取值（如更新版本写入的新选项）按默认值处理，不让整个配置读取失败。
        visibility = (try? c.decodeIfPresent(OverlayVisibility.self, forKey: .visibility)) ?? d.visibility
    }
}

/// 预警的设置。功能默认关闭，打开后才读聊天日志。
public struct IntelSettings: Sendable, Equatable, Codable {
    /// 保留时长的范围，单位是分钟。
    public static let windowMinutesRange: ClosedRange<Int> = 5...120
    /// 跳数计算上限的范围。
    public static let maxJumpsRange: ClosedRange<Int> = 1...30
    /// 高亮距离的范围；0 表示不高亮。
    public static let alertJumpsRange: ClosedRange<Int> = 0...30
    /// 频道列表的上限，翻译频道用同一个上限。
    public static let maxChannels = 16

    /// 是否显示预警浮窗并读聊天日志，默认 false。
    public var enabled: Bool
    /// 预警频道，默认为空，至多 16 项。
    public var channels: [ChannelRef]
    /// 早于这个时长的消息从浮窗里去掉，单位是分钟，默认 30，范围 5～120。
    public var windowMinutes: Int
    /// 跳数的计算上限，默认 15，范围 1～30。
    public var maxJumps: Int
    /// 敌对在这个跳数以内时高亮，默认 5，范围 0～30；0 表示不高亮。
    public var alertJumps: Int
    /// 每条下面是否显示原文，默认 true。
    public var showOriginal: Bool
    /// 参考星系的英文名；不知道角色位置时跳数从它算。默认 nil。
    public var referenceSystem: String?
    /// 是否向 CCP 的 ESI 核对人名（6.9 节），默认 true。预警关闭时不起作用，校验不管它。
    public var resolvePilotNames: Bool
    /// 预警浮窗的位置与外观。
    public var overlay: OverlayPanelSettings

    /// 用各字段建预警设置，默认值见各属性。
    public init(enabled: Bool = false, channels: [ChannelRef] = [], windowMinutes: Int = 30, maxJumps: Int = 15,
                alertJumps: Int = 5, showOriginal: Bool = true, referenceSystem: String? = nil,
                resolvePilotNames: Bool = true, overlay: OverlayPanelSettings = OverlayPanelSettings()) {
        self.enabled = enabled
        self.channels = channels
        self.windowMinutes = windowMinutes
        self.maxJumps = maxJumps
        self.alertJumps = alertJumps
        self.showOriginal = showOriginal
        self.referenceSystem = referenceSystem
        self.resolvePilotNames = resolvePilotNames
        self.overlay = overlay
    }

    /// 解码时缺失的键取默认值。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntelSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        channels = try c.decodeIfPresent([ChannelRef].self, forKey: .channels) ?? d.channels
        windowMinutes = try c.decodeIfPresent(Int.self, forKey: .windowMinutes) ?? d.windowMinutes
        maxJumps = try c.decodeIfPresent(Int.self, forKey: .maxJumps) ?? d.maxJumps
        alertJumps = try c.decodeIfPresent(Int.self, forKey: .alertJumps) ?? d.alertJumps
        showOriginal = try c.decodeIfPresent(Bool.self, forKey: .showOriginal) ?? d.showOriginal
        referenceSystem = try c.decodeIfPresent(String.self, forKey: .referenceSystem)
        resolvePilotNames = try c.decodeIfPresent(Bool.self, forKey: .resolvePilotNames) ?? d.resolvePilotNames
        overlay = try c.decodeIfPresent(OverlayPanelSettings.self, forKey: .overlay) ?? d.overlay
    }
}

/// 翻译的目标语言：跟随界面语言，或 8 种语言之一。
public enum TranslationTarget: String, Sendable, Codable, CaseIterable {
    /// 跟随界面语言，默认值。
    case ui
    /// 英文。
    case en
    /// 中文（简体）。
    case zh
    /// 俄文。
    case ru
    /// 日文。
    case ja
    /// 韩文。
    case ko
    /// 法文。
    case fr
    /// 德文。
    case de
    /// 西班牙文。
    case es

    /// 实际的目标语言：`ui` 取界面语言，其余取同名的语言。
    public func resolved(ui: AppLanguage) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? ui
    }
}

/// 聊天翻译的设置。功能默认关闭。
public struct TranslationSettings: Sendable, Equatable, Codable {
    /// 是否显示翻译浮窗，默认 false。
    public var enabled: Bool
    /// 翻译频道，默认为空，至多 16 项（`IntelSettings.maxChannels`）。
    public var channels: [ChannelRef]
    /// 目标语言，默认 `ui`（跟随界面语言）。
    public var targetLanguage: TranslationTarget
    /// 译文下面是否显示原文，默认 true。
    public var showOriginal: Bool
    /// 为真时只显示翻译过的消息，默认 false（Q22）。
    public var foreignOnly: Bool
    /// 翻译浮窗的位置与外观。
    public var overlay: OverlayPanelSettings

    /// 用各字段建翻译设置，默认值见各属性。
    public init(enabled: Bool = false, channels: [ChannelRef] = [], targetLanguage: TranslationTarget = .ui,
                showOriginal: Bool = true, foreignOnly: Bool = false,
                overlay: OverlayPanelSettings = OverlayPanelSettings()) {
        self.enabled = enabled
        self.channels = channels
        self.targetLanguage = targetLanguage
        self.showOriginal = showOriginal
        self.foreignOnly = foreignOnly
        self.overlay = overlay
    }

    /// 解码时缺失的键取默认值；`targetLanguage` 不认识或类型不对时取默认值，不抛错。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranslationSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        channels = try c.decodeIfPresent([ChannelRef].self, forKey: .channels) ?? d.channels
        targetLanguage = LenientDecoding.value(TranslationTarget.self, in: c, forKey: .targetLanguage,
                                               default: d.targetLanguage)
        showOriginal = try c.decodeIfPresent(Bool.self, forKey: .showOriginal) ?? d.showOriginal
        foreignOnly = try c.decodeIfPresent(Bool.self, forKey: .foreignOnly) ?? d.foreignOnly
        overlay = try c.decodeIfPresent(OverlayPanelSettings.self, forKey: .overlay) ?? d.overlay
    }
}

/// 模型服务的预设编号（7.3 节）。
public enum TranslationProviderID: String, Sendable, Codable, CaseIterable {
    /// DeepSeek，默认预设（Q26）。
    case deepseek
    /// Anthropic 的 Claude。
    case anthropic
    /// OpenAI。
    case openai
    /// 通义千问（DashScope 的 OpenAI 兼容接口）。
    case qwen
    /// Kimi（Moonshot）。
    case moonshot
    /// 本机的 Ollama。
    case ollama
    /// 其他 OpenAI 兼容接口，地址与模型由用户填写。
    case custom
}

/// 模型服务的地址与模型名，全局设置。空串表示用预设值。
public struct TranslationEndpointSettings: Sendable, Equatable, Codable {
    /// 服务预设，默认 `deepseek`。
    public var provider: TranslationProviderID
    /// 接口地址；空串表示用预设地址。
    public var baseURL: String
    /// 模型名；空串表示用预设模型。
    public var model: String

    /// 用各字段建接口设置，默认值见各属性。
    public init(provider: TranslationProviderID = .deepseek, baseURL: String = "", model: String = "") {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
    }

    /// 解码时缺失的键取默认值；`provider` 不认识或类型不对时取默认值，不抛错。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranslationEndpointSettings()
        provider = LenientDecoding.value(TranslationProviderID.self, in: c, forKey: .provider, default: d.provider)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    }
}
