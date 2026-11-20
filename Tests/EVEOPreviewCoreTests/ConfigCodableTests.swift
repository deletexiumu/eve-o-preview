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
        // eveLogDirectory 为 nil 时不写进 JSON。
        #expect(Set(general.keys) == ["pollIntervalMs", "onboardingCompleted", "language"])
        var withDirectory = AppConfig.makeDefault()
        withDirectory.general.eveLogDirectory = "~/EVE/logs"
        let generalWithDirectory = try #require(try jsonObject(withDirectory)["general"] as? [String: Any])
        #expect(Set(generalWithDirectory.keys) == ["pollIntervalMs", "onboardingCompleted", "language", "eveLogDirectory"])
        #expect(general["language"] as? String == "en")
    }

    /// 配置方案及各设置结构的键名与 5.2 节一致。
    @Test func profileKeyNames() throws {
        var profile = Profile(name: "X")
        profile.cycleGroups = [CycleGroup(name: "G")]
        let object = try jsonObject(profile)
        #expect(Set(object.keys) == ["id", "name", "thumbnail", "overlay", "behavior", "capture", "layouts",
                                     "loginPosition", "hiddenCharacters", "highlightColors", "cycleGroups",
                                     "characterHotkeys", "hotkeys", "hotkeyDefaultScope", "combatAlert"])
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
    @Test(arguments: [#""de""#, "5", "null", "true", #"{"x":1}"#])
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
