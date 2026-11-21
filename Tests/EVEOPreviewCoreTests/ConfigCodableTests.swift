// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置模型的编解码用例（架构文档 5.2 节、10.2 节）。

import Foundation
import Testing
import EVEOPreviewCore

/// 配置编解码：往返一致、缺键取默认、多余键忽略、键名与文档一致。
struct ConfigCodableTests {
    /// 编码为 JSON 对象，便于检查键名。
    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 解码一段 JSON 文本。
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// 默认配置编码再解码，结果相同。
    @Test func defaultRoundTrip() throws {
        var config = AppConfig.makeDefault()
        config.profiles[0].layouts = ["Pilot Alpha": ThumbnailLayout(x: 10, y: 20),
                                      "bravo pilot": ThumbnailLayout(x: 1, y: 2, width: 300, height: 200)]
        config.profiles[0].cycleGroups = [CycleGroup(name: "G", forwardHotkeys: ["F13"], members: ["A", "B"])]
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
    }

    /// 空对象解码出默认值：版本取当前版本，配置方案为空，全局设置取默认。
    @Test func emptyObjectUsesDefaults() throws {
        let config = try decode(AppConfig.self, "{}")
        #expect(config.schemaVersion == ConfigMigrator.currentSchemaVersion)
        #expect(config.profiles.isEmpty)
        #expect(config.general == GeneralSettings())
    }

    /// 配置方案只给部分键，其余取默认值。
    @Test func partialProfileUsesDefaults() throws {
        let json = #"{"profiles":[{"id":"p1","name":"X","thumbnail":{"opacity":0.8},"overlay":{}}]}"#
        let profile = try #require(try decode(AppConfig.self, json).profiles.first)
        #expect(profile.thumbnail.opacity == 0.8)
        #expect(profile.thumbnail.defaultSize == ScreenSize(width: 384, height: 216))
        #expect(profile.overlay == OverlaySettings())
        #expect(profile.behavior == BehaviorSettings())
        #expect(profile.capture == CaptureSettings())
        #expect(profile.loginPosition == ScreenPoint(x: 5, y: 40))
        #expect(profile.layouts.isEmpty && profile.cycleGroups.isEmpty)
    }

    /// 多余的键被忽略，不影响解码。
    @Test func unknownKeysIgnored() throws {
        let json = #"{"future":true,"profiles":[{"id":"p1","name":"X","extra":[1,2],"thumbnail":{"glow":1}}]}"#
        let config = try decode(AppConfig.self, json)
        #expect(config.profiles.first?.name == "X")
    }

    /// 无法识别的放大锚点取默认锚点，不把整个文件判为损坏。
    @Test func unknownZoomAnchorFallsBack() throws {
        let settings = try decode(ThumbnailSettings.self, #"{"zoomAnchor":"middle"}"#)
        #expect(settings.zoomAnchor == .nw)
        #expect(try decode(ThumbnailSettings.self, #"{"zoomAnchor":"se"}"#).zoomAnchor == .se)
    }

    /// 布局的宽高为 nil 时不写进 JSON；缺失时解码为 nil。
    @Test func layoutOptionalSize() throws {
        #expect(Set(try jsonObject(ThumbnailLayout(x: 1, y: 2)).keys) == ["x", "y"])
        let layout = try decode(ThumbnailLayout.self, #"{"x":3,"y":4}"#)
        #expect(layout == ThumbnailLayout(x: 3, y: 4, width: nil, height: nil))
    }

    /// 顶层与全局设置的键名与 5.2 节一致。
    @Test func topLevelKeyNames() throws {
        let object = try jsonObject(AppConfig.makeDefault())
        #expect(Set(object.keys) == ["schemaVersion", "activeProfileID", "profiles", "general"])
        let general = try #require(object["general"] as? [String: Any])
        // eveLogDirectory 为 nil 时不写进 JSON。v1.1 加了 4 个键（v1.1 设计 3.1 节、第 19 节），
        // 预警与翻译加了 translationEndpoint（docs/design-intel-translate.md 3.1 节）。
        let v11Keys: Set<String> = ["checkForUpdates", "autoInstallUpdates", "logLevel", "showDockIcon",
                                    "translationEndpoint"]
        #expect(Set(general.keys) == Set(["pollIntervalMs", "onboardingCompleted", "language"]).union(v11Keys))
        var withDirectory = AppConfig.makeDefault()
        withDirectory.general.eveLogDirectory = "~/EVE/logs"
        let generalWithDirectory = try #require(try jsonObject(withDirectory)["general"] as? [String: Any])
        #expect(Set(generalWithDirectory.keys)
            == Set(["pollIntervalMs", "onboardingCompleted", "language", "eveLogDirectory"]).union(v11Keys))
        #expect(general["language"] as? String == "en")
    }

    /// 配置方案及各设置结构的键名与 5.2 节一致。
    @Test func profileKeyNames() throws {
        var profile = Profile(name: "X")
        profile.cycleGroups = [CycleGroup(name: "G")]
        let object = try jsonObject(profile)
        #expect(Set(object.keys) == ["id", "name", "thumbnail", "overlay", "behavior", "capture", "layouts",
                                     "loginPosition", "hiddenCharacters", "highlightColors", "cycleGroups",
                                     "characterHotkeys", "hotkeys", "hotkeyDefaultScope", "combatAlert",
                                     "intel", "translation"])
        let thumbnail = try #require(object["thumbnail"] as? [String: Any])
        #expect(Set(thumbnail.keys) == ["defaultSize", "minimumSize", "maximumSize", "opacity", "zoomEnabled",
                                        "zoomFactor", "zoomAnchor", "snapEnabled", "lockAspectRatio"])
        #expect(Set(try #require(thumbnail["defaultSize"] as? [String: Any]).keys) == ["width", "height"])
        #expect(Set(try #require(object["overlay"] as? [String: Any]).keys)
            == ["showTitle", "titleFontSize", "titleColor", "highlightEnabled", "highlightColor", "highlightThickness",
                "borderEnabled", "borderColor", "borderThickness"])
        #expect(Set(try #require(object["combatAlert"] as? [String: Any]).keys)
            == ["enabled", "color", "durationSeconds", "style", "includeMisses", "minimumDamage"])
        #expect(object["hotkeyDefaultScope"] as? String == "global")
        #expect(Set(try #require(object["behavior"] as? [String: Any]).keys)
            == ["alwaysOnTop", "hideActiveClientThumbnail", "hideWhenEVENotFrontmost", "hideDelaySeconds", "lockLayout"])
        #expect(Set(try #require(object["capture"] as? [String: Any]).keys) == ["frameRate", "titleBarCropHeight"])
        #expect(Set(try #require(object["loginPosition"] as? [String: Any]).keys) == ["x", "y"])
        #expect(Set(try #require(object["hotkeys"] as? [String: Any]).keys)
            == ["toggleHideAll", "minimizeAll", "cycleLoginClients"])
        let group = try #require((object["cycleGroups"] as? [[String: Any]])?.first)
        #expect(Set(group.keys) == ["id", "name", "forwardHotkeys", "backwardHotkeys", "members"])
    }

    /// 默认值与 5.2 节的注释一致。
    @Test func documentedDefaults() {
        let t = ThumbnailSettings()
        #expect(t.minimumSize == ScreenSize(width: 192, height: 108))
        #expect(t.maximumSize == ScreenSize(width: 960, height: 540))
        #expect(t.opacity == 0.5 && !t.zoomEnabled && t.zoomFactor == 2 && t.zoomAnchor == .nw)
        #expect(t.snapEnabled && !t.lockAspectRatio)
        let o = OverlaySettings()
        #expect(o.showTitle && o.titleFontSize == 12 && o.titleColor == "#FFFFFF")
        #expect(!o.highlightEnabled && o.highlightColor == "#ADFF2F" && o.highlightThickness == 3)
        #expect(o.borderEnabled && o.borderColor == "#C0C0C0" && o.borderThickness == 2)
        let a = CombatAlertSettings()
        #expect(!a.enabled && a.color == "#FF3B30" && a.durationSeconds == 3.0 && a.style == .both)
        #expect(a.includeMisses && a.minimumDamage == 1)
        #expect(Profile(name: "X").hotkeyDefaultScope == .global)
        let b = BehaviorSettings()
        #expect(b.alwaysOnTop && !b.hideActiveClientThumbnail && !b.hideWhenEVENotFrontmost)
        #expect(b.hideDelaySeconds == 1.0 && !b.lockLayout)
        #expect(CaptureSettings() == CaptureSettings(frameRate: 15, titleBarCropHeight: 28))
        #expect(GeneralSettings() == GeneralSettings(pollIntervalMs: 1000, onboardingCompleted: false,
                                                     language: .en, eveLogDirectory: nil))
        let config = AppConfig.makeDefault()
        #expect(config.profiles.map(\.name) == ["Default"] && config.activeProfileID == config.profiles[0].id)
    }
}

// MARK: - 第一轮反馈的新键（反馈文档 3.1 节、3.2 节）

extension ConfigCodableTests {
    /// v1 留下的配置文件缺少全部新键：取默认值。
    @Test func v1FileGetsNewDefaults() throws {
        let json = #"""
        {"schemaVersion":1,"activeProfileID":"p1","general":{"pollIntervalMs":800,"onboardingCompleted":true},
         "profiles":[{"id":"p1","name":"Main","overlay":{"highlightEnabled":true}}]}
        """#
        let config = try decode(AppConfig.self, json)
        #expect(config.general.language == .en && config.general.eveLogDirectory == nil)
        #expect(config.general.pollIntervalMs == 800)
        let profile = try #require(config.profiles.first)
        #expect(profile.overlay.highlightEnabled)
        #expect(profile.overlay.borderEnabled && profile.overlay.borderColor == "#C0C0C0")
        #expect(profile.overlay.borderThickness == 2)
        #expect(profile.hotkeyDefaultScope == .global)
        #expect(profile.combatAlert == CombatAlertSettings())
        #expect(!profile.combatAlert.enabled)
    }

    /// 新键的取值能读出来。
    @Test func newKeysDecode() throws {
        let json = #"""
        {"general":{"language":"ja","eveLogDirectory":"~/EVE/logs"},
         "profiles":[{"id":"p1","name":"X","hotkeyDefaultScope":"game",
                      "overlay":{"borderEnabled":false,"borderColor":"#112233","borderThickness":4},
                      "combatAlert":{"enabled":true,"color":"#00FF00","durationSeconds":5.5,"style":"wash",
                                     "includeMisses":false,"minimumDamage":50}}]}
        """#
        let config = try decode(AppConfig.self, json)
        #expect(config.general.language == .ja && config.general.eveLogDirectory == "~/EVE/logs")
        let profile = try #require(config.profiles.first)
        #expect(profile.hotkeyDefaultScope == .game)
        #expect(profile.overlay == OverlaySettings(borderEnabled: false, borderColor: "#112233", borderThickness: 4))
        #expect(profile.combatAlert == CombatAlertSettings(enabled: true, color: "#00FF00", durationSeconds: 5.5,
                                                           style: .wash, includeMisses: false, minimumDamage: 50))
    }

    /// 3 个枚举键的值不认识或类型不对时取默认值，不抛错，整个文件照常解码。
    @Test(arguments: [#""it""#, "5", "null", "true", #"{"x":1}"#])
    func unknownEnumValuesFallBack(raw: String) throws {
        let json = """
        {"general":{"language":\(raw),"pollIntervalMs":700},
         "profiles":[{"id":"p1","name":"X","hotkeyDefaultScope":\(raw),"combatAlert":{"style":\(raw),"enabled":true}}]}
        """
        let config = try decode(AppConfig.self, json)
        #expect(config.general.language == .en && config.general.pollIntervalMs == 700)
        let profile = try #require(config.profiles.first)
        #expect(profile.hotkeyDefaultScope == .global)
        #expect(profile.combatAlert.style == .both && profile.combatAlert.enabled)
    }

    /// 全部新键改过的配置编码再解码，结果相同。
    @Test func newKeysRoundTrip() throws {
        var config = AppConfig.makeDefault()
        config.general.language = .system
        config.general.eveLogDirectory = "/tmp/Gamelogs"
        config.updateActiveProfile { profile in
            profile.hotkeyDefaultScope = .game
            profile.overlay.borderEnabled = false
            profile.overlay.borderThickness = 5
            profile.combatAlert = CombatAlertSettings(enabled: true, durationSeconds: 7, style: .border,
                                                      includeMisses: false, minimumDamage: 200)
        }
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
    }
}

// MARK: - v1.1 的新键（v1.1 设计 3.1 节、3.2 节）

extension ConfigCodableTests {
    /// 1.0.0 写的文件没有 4 个新键：取默认值（检查更新开、自动安装开、级别 info、显示 Dock 图标）。
    @Test func v100FileGetsUpdateAndLogDefaults() throws {
        let json = #"""
        {"schemaVersion":1,"activeProfileID":"p1",
         "general":{"pollIntervalMs":800,"onboardingCompleted":true,"language":"zh"},
         "profiles":[{"id":"p1","name":"Main"}]}
        """#
        let config = try decode(AppConfig.self, json)
        #expect(config.general.checkForUpdates)
        #expect(config.general.autoInstallUpdates)
        #expect(config.general.logLevel == .info)
        #expect(config.general.showDockIcon)
        #expect(config.general.pollIntervalMs == 800 && config.general.language == .zh)
    }

    /// 4 个新键的键名、类型与默认值和 3.1 节、第 19 节一致。
    @Test func v11KeyNamesAndDefaults() throws {
        let general = try #require(try jsonObject(AppConfig.makeDefault())["general"] as? [String: Any])
        #expect(general["checkForUpdates"] as? Bool == true)
        #expect(general["autoInstallUpdates"] as? Bool == true)
        #expect(general["logLevel"] as? String == "info")
        #expect(general["showDockIcon"] as? Bool == true)
        let defaults = GeneralSettings()
        #expect(defaults.checkForUpdates && defaults.autoInstallUpdates && defaults.logLevel == .info)
        #expect(defaults.showDockIcon)
    }

    /// 新键的取值能读出来。
    @Test func v11KeysDecode() throws {
        let json = #"{"general":{"checkForUpdates":false,"autoInstallUpdates":false,"logLevel":"debug","showDockIcon":false}}"#
        let general = try decode(AppConfig.self, json).general
        #expect(!general.checkForUpdates && !general.autoInstallUpdates && general.logLevel == .debug)
        #expect(!general.showDockIcon)
    }

    /// `logLevel` 是不认识的值或类型不对时取 info，不抛错，其余字段照常解码。
    @Test(arguments: [#""verbose""#, #""INFO""#, "5", "null", "true", #"{"x":1}"#])
    func unknownLogLevelFallsBack(raw: String) throws {
        let json = #"{"general":{"logLevel":\#(raw),"checkForUpdates":false,"pollIntervalMs":700}}"#
        let general = try decode(AppConfig.self, json).general
        #expect(general.logLevel == .info)
        #expect(!general.checkForUpdates && general.pollIntervalMs == 700)
    }

    /// 合法但不在 info 与 debug 之列的级别（如 error）解码时照原样读出，由 ConfigValidator 改回 info。
    @Test func otherLogLevelsDecodeAsIs() throws {
        let general = try decode(AppConfig.self, #"{"general":{"logLevel":"error"}}"#).general
        #expect(general.logLevel == .error)
    }

    /// 改过 4 个新键的配置编码再解码，结果相同。
    @Test func v11KeysRoundTrip() throws {
        var config = AppConfig.makeDefault()
        config.general.checkForUpdates = false
        config.general.autoInstallUpdates = false
        config.general.logLevel = .debug
        config.general.showDockIcon = false
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
    }

    /// 1.1.0 写出的文件被 1.0.0 保存过（4 个新键丢失）后再读：新键回到默认值，其余字段不变。
    @Test func downgradeRoundTripKeepsOtherFields() throws {
        var config = AppConfig.makeDefault()
        config.general.pollIntervalMs = 1500
        config.general.language = .ko
        config.general.eveLogDirectory = "~/EVE/logs"
        config.general.checkForUpdates = false
        config.general.autoInstallUpdates = false
        config.general.logLevel = .debug
        config.general.showDockIcon = false
        config.updateActiveProfile { $0.layouts = ["Pilot": ThumbnailLayout(x: 1, y: 2)] }
        var object = try jsonObject(config)
        var general = try #require(object["general"] as? [String: Any])
        for key in ["checkForUpdates", "autoInstallUpdates", "logLevel", "showDockIcon"] {
            general[key] = nil
        }
        object["general"] = general
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: stripped)
        var expected = config
        expected.general.checkForUpdates = true
        expected.general.autoInstallUpdates = true
        expected.general.logLevel = .info
        expected.general.showDockIcon = true
        #expect(reloaded == expected)
    }
}

/// 预警与翻译设置的编解码（docs/design-intel-translate.md 3.1 节、3.2 节、14.1 节）。频道名是虚构的。
struct ChatConfigCodableTests {
    /// 编码为 JSON 对象，便于检查键名。
    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 缺少全部新键的旧文件：两个功能都关闭，各项取默认值。
    @Test func oldFileUsesDefaults() throws {
        let json = #"{"schemaVersion":1,"activeProfileID":"p","profiles":[{"id":"p","name":"Main"}],"general":{}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let profile = config.profiles[0]
        #expect(profile.intel == IntelSettings() && profile.translation == TranslationSettings())
        #expect(!profile.intel.enabled && !profile.translation.enabled)
        #expect(profile.intel.windowMinutes == 30 && profile.intel.maxJumps == 15 && profile.intel.alertJumps == 5)
        #expect(profile.intel.showOriginal && profile.intel.referenceSystem == nil)
        #expect(profile.intel.resolvePilotNames)
        #expect(profile.intel.overlay == OverlayPanelSettings(frame: nil, opacity: 0.75, fontSize: 12))
        #expect(profile.translation.targetLanguage == .ui && profile.translation.showOriginal)
        #expect(!profile.translation.foreignOnly)
        #expect(config.general.translationEndpoint == TranslationEndpointSettings(provider: .deepseek))
    }

    /// 新键的 JSON 名称与 3.1 节一致。
    @Test func keyNames() throws {
        var profile = Profile(name: "Main")
        profile.intel.referenceSystem = "Jita"
        profile.intel.overlay.frame = ScreenRect(x: 1, y: 2, width: 300, height: 200)
        let object = try jsonObject(profile)
        let intel = try #require(object["intel"] as? [String: Any])
        #expect(Set(intel.keys) == ["enabled", "channels", "windowMinutes", "maxJumps", "alertJumps", "showOriginal",
                                    "referenceSystem", "resolvePilotNames", "overlay"])
        let overlay = try #require(intel["overlay"] as? [String: Any])
        #expect(Set(overlay.keys) == ["frame", "opacity", "fontSize"])
        #expect(Set((overlay["frame"] as? [String: Any])?.keys ?? [:].keys) == ["x", "y", "width", "height"])
        let translation = try #require(object["translation"] as? [String: Any])
        #expect(Set(translation.keys) == ["enabled", "channels", "targetLanguage", "showOriginal", "foreignOnly",
                                          "overlay"])
        let general = try jsonObject(GeneralSettings())
        let endpoint = try #require(general["translationEndpoint"] as? [String: Any])
        #expect(Set(endpoint.keys) == ["provider", "baseURL", "model"])
        #expect(endpoint["provider"] as? String == "deepseek")
    }

    /// resolvePilotNames（6.9 节）：缺失时取 true；写成 false 时往返一致，其他键不受影响。
    @Test func resolvePilotNamesCoding() throws {
        let missing = try JSONDecoder().decode(IntelSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        #expect(missing.resolvePilotNames && missing.enabled)
        let off = try JSONDecoder().decode(IntelSettings.self, from: Data(#"{"resolvePilotNames":false}"#.utf8))
        #expect(!off.resolvePilotNames && !off.enabled && off.maxJumps == 15)
        #expect(try jsonObject(off)["resolvePilotNames"] as? Bool == false)
        var config = AppConfig.makeDefault()
        config.profiles[0].intel.resolvePilotNames = false
        let again = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(again == config && !again.profiles[0].intel.resolvePilotNames)
    }

    /// targetLanguage 与 provider 是不认识的值时取默认值，不抛错。
    @Test func unknownEnumValues() throws {
        let translation = try JSONDecoder().decode(TranslationSettings.self,
                                                   from: Data(#"{"targetLanguage":"tlh","enabled":true}"#.utf8))
        #expect(translation.targetLanguage == .ui && translation.enabled)
        let endpoint = try JSONDecoder().decode(TranslationEndpointSettings.self,
                                                from: Data(#"{"provider":42,"model":"m"}"#.utf8))
        #expect(endpoint.provider == .deepseek && endpoint.model == "m")
    }

    /// ChannelRef 没有 id 时编码里省略 id；解码时 name 缺失为空串。
    @Test func channelRefCoding() throws {
        let object = try jsonObject(ChannelRef(name: "intel.Demo"))
        #expect(Set(object.keys) == ["name"])
        let decoded = try JSONDecoder().decode(ChannelRef.self, from: Data(#"{"id":"corp"}"#.utf8))
        #expect(decoded == ChannelRef(name: "", id: "corp"))
    }

    /// 改过新键的配置往返一致。
    @Test func roundTrip() throws {
        var config = AppConfig.makeDefault()
        config.profiles[0].intel = IntelSettings(enabled: true, channels: [ChannelRef(name: "intel.Demo", id: "player_1")],
                                                 windowMinutes: 45, maxJumps: 10, alertJumps: 3, showOriginal: false,
                                                 referenceSystem: "Jita",
                                                 overlay: OverlayPanelSettings(frame: ScreenRect(x: 5, y: 6, width: 400,
                                                                                                 height: 300),
                                                                               opacity: 0.5, fontSize: 14))
        config.profiles[0].translation = TranslationSettings(enabled: true, channels: [.local], targetLanguage: .ko,
                                                             showOriginal: false, foreignOnly: true)
        config.general.translationEndpoint = TranslationEndpointSettings(provider: .ollama, baseURL: "http://h:1",
                                                                         model: "qwen")
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
    }
}
