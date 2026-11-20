// SPDX-License-Identifier: GPL-3.0-or-later
//
// 热键作用范围、鼠标热键、界面语言与宽松解码的边界用例（反馈文档 3.2 节、6.1～6.6 节、10.1 节），
// 由测试方在集成后补充。只补已有用例没写到、但规则推得出的情况。

import Foundation
import Testing
import EVEOPreviewCore

// MARK: - 热键字符串

/// 热键字符串的边界写法。
struct HotkeySyntaxEdgeCaseTests {
    /// 序号与 Mouse 之间有空白、序号带正负号、序号是小数：解析失败。
    @Test(arguments: ["Mouse 4", "Mouse+4", "Mouse4.0", "Mouse 4@game", "ctrl+Mouse 3", "Mouse\t4"])
    func malformedMouseOrdinal(text: String) {
        #expect(HotkeySpec(string: text) == nil)
    }

    /// 带前导 0 的序号按十进制读，输出规范写法（不带前导 0）。
    @Test func leadingZeroOrdinalCanonicalized() {
        #expect(Hotkey(string: "Mouse04")?.stringValue() == "Mouse4")
        #expect(Hotkey(string: "Mouse002") == nil)
    }

    /// 修饰键段之间与 `@` 两侧都有空白时，规范写法去掉空白、修饰键按固定顺序。
    @Test func whitespaceEverywhere() {
        #expect(HotkeySpec(string: "  shift +  ctrl + Mouse32  @  global ")?.stringValue() == "ctrl+shift+Mouse32@global")
    }

    /// 作用范围不能写成前缀或用别的分隔符。
    @Test(arguments: ["game@F13", "F13#game", "F13:game", "F13@games", "F13@gam"])
    func wrongSuffixForms(text: String) {
        #expect(HotkeySpec(string: text) == nil)
    }
}

// MARK: - 规划

/// 规划器在作用范围与鼠标触发键上的边界。
struct HotkeyPlannerScopeEdgeCaseTests {
    /// 解析一个热键，失败时让用例失败。
    private func key(_ text: String) -> Hotkey {
        guard let hotkey = Hotkey(string: text) else {
            Issue.record("无法解析 \(text)")
            return Hotkey(keyCode: 0, modifiers: [])
        }
        return hotkey
    }

    /// 带作用范围后缀的键盘热键照常检查缺修饰键与系统保留，后缀不豁免。
    @Test func suffixDoesNotBypassKeyboardChecks() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["A@game", "cmd+Q@game", "cmd+shift+Tab@global"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.isEmpty)
        #expect(plan.issues == [
            .rejected(hotkey: key("A"), action: .toggleHideAll, reason: .missingModifier),
            .rejected(hotkey: key("cmd+Q"), action: .toggleHideAll, reason: .systemReserved),
            .rejected(hotkey: key("cmd+shift+Tab"), action: .toggleHideAll, reason: .systemReserved),
        ])
    }

    /// 系统保留的名单只管键盘：cmd+Mouse4、cmd+shift+Mouse3 被接受。
    @Test func reservedListIgnoresMouse() {
        #expect(HotkeyPlanner.rejection(for: key("cmd+Mouse4")) == nil)
        #expect(HotkeyPlanner.rejection(for: key("cmd+shift+Mouse3")) == nil)
    }

    /// 作用范围对 5 种动作都有效：默认范围是 game 时，没有后缀的每条绑定都取 game，带后缀的取后缀。
    @Test func defaultScopeAppliesToAllFiveActions() {
        var profile = Profile(name: "P")
        profile.hotkeyDefaultScope = .game
        profile.hotkeys = GeneralHotkeys(toggleHideAll: ["F13"], minimizeAll: ["F14@global"],
                                         cycleLoginClients: ["Mouse3"])
        profile.cycleGroups = [CycleGroup(id: "g", name: "G", forwardHotkeys: ["Mouse4"],
                                          backwardHotkeys: ["Mouse5@global"])]
        profile.characterHotkeys = ["Aurora Vale": ["ctrl+Mouse6"]]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.issues.isEmpty)
        #expect(plan.bindings.map(\.action) == [
            .toggleHideAll, .minimizeAll, .cycleLoginClients, .cycle(groupID: "g", direction: .forward),
            .cycle(groupID: "g", direction: .backward), .activateCharacter("Aurora Vale"),
        ])
        #expect(plan.bindings.map(\.scope) == [.game, .global, .game, .game, .global, .game])
    }

    /// 鼠标热键的重复：同一按键大小写不同、带与不带后缀，都按同一个热键处理；修饰键不同不算重复。
    @Test func mouseDuplicatesIgnoreCaseAndScope() {
        var profile = Profile(name: "P")
        profile.hotkeys.toggleHideAll = ["mouse4@game", "MOUSE4", "shift+Mouse4"]
        let plan = HotkeyPlanner.plan(for: profile)
        #expect(plan.bindings.map(\.hotkey) == [key("Mouse4"), key("shift+Mouse4")])
        #expect(plan.issues == [.duplicate(hotkey: key("Mouse4"), kept: .toggleHideAll, dropped: .toggleHideAll)])
    }
}

// MARK: - 鼠标匹配器

/// 鼠标匹配器在多个按键同时按住、暂停时按住等情况下的行为。
struct MouseHotkeyMatcherEdgeCaseTests {
    /// 建一条鼠标绑定。
    private func binding(_ id: UInt32, button: Int, scope: HotkeyScope = .global) -> MouseHotkeyMatcher.Binding {
        MouseHotkeyMatcher.Binding(id: id, button: button, modifiers: [], scope: scope)
    }

    /// 两个已绑定的按键交错按下与松开：各自吞掉自己的拖动与松开，互不影响。
    @Test func twoButtonsInterleaved() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3), binding(2, button: 4)])
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        #expect(matcher.handle(.down, button: 4, modifiers: []) == .fire(2))
        #expect(matcher.swallowedButtons == [3, 4])
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
        #expect(matcher.handle(.dragged, button: 4, modifiers: []) == .swallow)
        #expect(matcher.handle(.dragged, button: 3, modifiers: []) == .pass)
        #expect(matcher.handle(.up, button: 4, modifiers: []) == .swallow)
        #expect(matcher.swallowedButtons.isEmpty)
    }

    /// 已绑定的按键按住时，另一个未绑定的按键的整次点击放行。
    @Test func unboundButtonWhileBoundHeld() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        #expect(matcher.handle(.down, button: 2, modifiers: []) == .pass)
        #expect(matcher.handle(.up, button: 2, modifiers: []) == .pass)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
    }

    /// 按住已绑定的按键时开始录制（暂停）：监听为这次松开保持打开，松开照样吞掉，之后关闭；恢复后照常触发。
    @Test func suspendWhileHeld() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
        matcher.setSuspended(true)
        #expect(matcher.shouldListen)
        #expect(matcher.handle(.dragged, button: 3, modifiers: []) == .swallow)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
        #expect(!matcher.shouldListen)
        // 暂停期间新的按下放行，它的松开也放行。
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .pass)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .pass)
        matcher.setSuspended(false)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .fire(1))
    }

    /// 清空绑定表时还按着已吞掉的按键：等这次松开吞掉后监听才关闭，之后任何事件都放行。
    @Test func emptyBindingsStopListening() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        _ = matcher.handle(.down, button: 3, modifiers: [])
        matcher.replaceBindings([])
        #expect(matcher.shouldListen)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
        #expect(!matcher.shouldListen)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .pass)
        #expect(matcher.handle(.down, button: 3, modifiers: []) == .pass)
    }

    /// 前台状态反复变化而值不变时，已吞掉的按钮号不受影响（只有 global 绑定时监听一直开着）。
    @Test func repeatedFrontmostUpdatesKeepState() {
        var matcher = MouseHotkeyMatcher()
        matcher.replaceBindings([binding(1, button: 3)])
        _ = matcher.handle(.down, button: 3, modifiers: [])
        matcher.setGameFrontmost(false)
        matcher.setGameFrontmost(true)
        matcher.setGameFrontmost(false)
        #expect(matcher.handle(.up, button: 3, modifiers: []) == .swallow)
    }
}

// MARK: - 界面语言

/// 语言解析的边界。
struct AppLanguageEdgeCaseTests {
    /// 下划线写法、只有语言代码、带脚本与地区：都按开头的语言代码匹配。
    @Test(arguments: [("zh_CN", AppLanguage.zh), ("ja", .ja), ("ru-UA", .ru), ("ko-Kore-KR", .ko),
                      ("en-GB", .en), ("  zh-Hant-HK ", .zh)])
    func codeForms(code: String, expected: AppLanguage) {
        #expect(LanguagePreference.system.resolved(preferredLanguages: [code], override: nil) == expected)
    }

    /// 首选语言里的空串与空白被跳过。
    @Test func blankPreferredLanguagesSkipped() {
        #expect(LanguagePreference.system.resolved(preferredLanguages: ["", "  ", "ko-KR"], override: nil) == .ko)
    }

    /// override 只对受支持的代码生效；`system`、`jp` 这类不是语言代码的值被忽略。
    @Test func overrideOnlyForSupportedCodes() {
        #expect(LanguagePreference.zh.resolved(preferredLanguages: [], override: "system") == .zh)
        #expect(LanguagePreference.ko.resolved(preferredLanguages: [], override: "jp") == .ko)
        #expect(LanguagePreference.system.resolved(preferredLanguages: ["ja-JP"], override: nil) == .ja)
    }

    /// 只比第一个子标签：`kok`（孔卡尼语）、`rue`（卢森尼亚语）、`jam`（牙买加克里奥尔语）、`zha`（壮语）
    /// 虽以 ko、ru、ja、zh 开头，也不算受支持的语言，跳过后取后面的 en。
    @Test func primarySubtagOnly() {
        for code in ["kok-IN", "rue-UA", "jam", "zha"] {
            #expect(LanguagePreference.system.resolved(preferredLanguages: [code, "en-US"], override: nil) == .en,
                    "\(code)")
        }
    }

    /// 受支持的语言带脚本或地区子标签时照常匹配。
    @Test(arguments: [("zh-Hans-CN", AppLanguage.zh), ("ja-JP", .ja), ("ko", .ko), ("ru-RU", .ru), ("zh_TW", .zh)])
    func supportedWithSubtags(code: String, expected: AppLanguage) {
        #expect(LanguagePreference.system.resolved(preferredLanguages: [code, "en-US"], override: nil) == expected)
    }
}

// MARK: - 宽松解码

/// LenientDecoding 本身，以及经 JSONFileConfigStore 读文件时的结果。
struct LenientDecodingEdgeCaseTests {
    /// 只含一个枚举键的小类型，用来直接测 LenientDecoding。
    private struct Holder: Decodable {
        /// 解码结果。
        var scope: HotkeyScope
        /// 键名。
        enum CodingKeys: String, CodingKey { case scope }
        /// 用宽松解码读 scope，默认 game。
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scope = LenientDecoding.value(HotkeyScope.self, in: c, forKey: .scope, default: .game)
        }
    }

    /// 键缺失、null、类型不对、值不认识、大小写不同、空串：都取默认值；认识的值照常读出。
    @Test(arguments: [("{}", HotkeyScope.game), (#"{"scope":null}"#, .game), (#"{"scope":1}"#, .game),
                      (#"{"scope":"world"}"#, .game), (#"{"scope":"GLOBAL"}"#, .game), (#"{"scope":""}"#, .game),
                      (#"{"scope":["global"]}"#, .game), (#"{"scope":"global"}"#, .global)])
    func holder(json: String, expected: HotkeyScope) throws {
        let value = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        #expect(value.scope == expected)
    }

    /// 经配置文件读取：3 个枚举键都是不认识的值时，文件不被隔离，没有警告，其他键照常读出；
    /// 下次保存时写回默认值（3.2 节）。
    @Test func storeLoadsUnknownEnumsWithoutQuarantine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eveo-lenient-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let json = #"""
        {"schemaVersion":1,"activeProfileID":"p1",
         "general":{"pollIntervalMs":900,"onboardingCompleted":true,"language":"de"},
         "profiles":[{"id":"p1","name":"Main","hotkeyDefaultScope":"everywhere",
                      "combatAlert":{"enabled":true,"style":"strobe","minimumDamage":20}}]}
        """#
        try Data(json.utf8).write(to: store.fileURL)
        let result = try store.load()
        #expect(result.warnings.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])
        #expect(result.config.general.language == .en && result.config.general.pollIntervalMs == 900)
        let profile = try #require(result.config.profiles.first)
        #expect(profile.name == "Main" && profile.hotkeyDefaultScope == .global)
        #expect(profile.combatAlert.style == .both && profile.combatAlert.enabled && profile.combatAlert.minimumDamage == 20)
        // 保存后文件里是默认值。
        try store.save(result.config)
        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let general = try #require(saved["general"] as? [String: Any])
        #expect(general["language"] as? String == "en")
    }
}
