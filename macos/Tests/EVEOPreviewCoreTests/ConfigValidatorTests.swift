// SPDX-License-Identifier: GPL-3.0-or-later
//
// ConfigValidator 的用例（架构文档 5.2 节、10.2 节）。

import Testing
import EVEOPreviewCore

/// 配置校验：各范围的上下界、空列表、失效的当前方案、重名与幂等。
struct ConfigValidatorTests {
    /// 只含一个配置方案的配置，便于修改后校验。
    private func config(_ edit: (inout Profile) -> Void) -> AppConfig {
        var profile = Profile(id: "p1", name: "Main")
        edit(&profile)
        return AppConfig(activeProfileID: "p1", profiles: [profile])
    }

    /// 默认配置是无操作，重复校验结果不变。
    @Test func defaultsAreUntouched() {
        let original = AppConfig.makeDefault()
        let once = ConfigValidator.normalized(original)
        #expect(once.clamped.isEmpty)
        #expect(once.config == original)
        let twice = ConfigValidator.normalized(once.config)
        #expect(twice.clamped.isEmpty && twice.config == once.config)
    }

    /// 每个数值范围的下界：低于下界夹到下界，并记录字段路径。
    @Test func lowerBounds() {
        var input = config {
            $0.thumbnail.opacity = 0.1; $0.thumbnail.zoomFactor = 1
            $0.overlay.titleFontSize = 4; $0.overlay.highlightThickness = 0
            $0.behavior.hideDelaySeconds = -1
            $0.capture.frameRate = 0; $0.capture.titleBarCropHeight = -5
        }
        input.general.pollIntervalMs = 100
        let (result, clamped) = ConfigValidator.normalized(input)
        let p = result.profiles[0]
        #expect(p.thumbnail.opacity == 0.2 && p.thumbnail.zoomFactor == 2)
        #expect(p.overlay.titleFontSize == 8 && p.overlay.highlightThickness == 1)
        #expect(p.behavior.hideDelaySeconds == 0)
        #expect(p.capture.frameRate == 1 && p.capture.titleBarCropHeight == 0)
        #expect(result.general.pollIntervalMs == 300)
        #expect(Set(clamped) == ["profiles[0].thumbnail.opacity", "profiles[0].thumbnail.zoomFactor",
                                 "profiles[0].overlay.titleFontSize", "profiles[0].overlay.highlightThickness",
                                 "profiles[0].behavior.hideDelaySeconds", "profiles[0].capture.frameRate",
                                 "profiles[0].capture.titleBarCropHeight", "general.pollIntervalMs"])
    }

    /// 每个数值范围的上界。
    @Test func upperBounds() {
        var input = config {
            $0.thumbnail.opacity = 1.5; $0.thumbnail.zoomFactor = 11
            $0.overlay.titleFontSize = 37; $0.overlay.highlightThickness = 7
            $0.behavior.hideDelaySeconds = 11
            $0.capture.frameRate = 61; $0.capture.titleBarCropHeight = 61
        }
        input.general.pollIntervalMs = 2001
        let p = ConfigValidator.normalized(input).config.profiles[0]
        #expect(p.thumbnail.opacity == 1.0 && p.thumbnail.zoomFactor == 10)
        #expect(p.overlay.titleFontSize == 36 && p.overlay.highlightThickness == 6)
        #expect(p.behavior.hideDelaySeconds == 10)
        #expect(p.capture.frameRate == 60 && p.capture.titleBarCropHeight == 60)
        #expect(ConfigValidator.normalized(input).config.general.pollIntervalMs == 2000)
    }

    /// 恰好在边界上的值不改。
    @Test func exactBoundsAreKept() {
        var input = config {
            $0.thumbnail.opacity = 0.2; $0.thumbnail.zoomFactor = 10
            $0.overlay.titleFontSize = 36; $0.capture.frameRate = 60; $0.capture.titleBarCropHeight = 0
            $0.behavior.hideDelaySeconds = 10
        }
        input.general.pollIntervalMs = 300
        #expect(ConfigValidator.normalized(input).clamped.isEmpty)
    }

    /// 尺寸关系：最大不小于最小，默认尺寸夹在两者之间；NaN 改回默认并夹到范围内。
    @Test func sizeRelationships() {
        let input = config {
            $0.thumbnail.minimumSize = ScreenSize(width: 500, height: 10)
            $0.thumbnail.maximumSize = ScreenSize(width: 400, height: .nan)
            $0.thumbnail.defaultSize = ScreenSize(width: 100, height: 9000)
        }
        let (result, _) = ConfigValidator.normalized(input)
        let t = result.profiles[0].thumbnail
        #expect(t.minimumSize == ScreenSize(width: 500, height: 32))
        #expect(t.maximumSize == ScreenSize(width: 500, height: 540))
        #expect(t.defaultSize == ScreenSize(width: 500, height: 540))
        #expect(ConfigValidator.normalized(result).clamped.isEmpty)
    }

    /// 空的配置方案列表：补一个 Default，并设为当前方案。
    @Test func emptyProfileList() {
        let input = AppConfig(activeProfileID: "missing", profiles: [])
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(result.profiles.map(\.name) == ["Default"])
        #expect(result.activeProfileID == result.profiles[0].id)
        #expect(clamped.contains("profiles") && clamped.contains("activeProfileID"))
    }

    /// 失效的 activeProfileID 改为第一个配置方案。
    @Test func invalidActiveProfile() {
        let input = AppConfig(activeProfileID: "gone", profiles: [Profile(id: "a", name: "A"), Profile(id: "b", name: "B")])
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(result.activeProfileID == "a")
        #expect(clamped == ["activeProfileID"])
    }

    /// 重复与空的 id 换新；名称去空白、补默认、不区分大小写去重。
    @Test func duplicateIDsAndNames() {
        let input = AppConfig(activeProfileID: "a", profiles: [
            Profile(id: "a", name: "Main"), Profile(id: "a", name: "main "), Profile(id: "", name: "   "),
            Profile(id: "d", name: "MAIN"),
        ])
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(Set(result.profiles.map(\.id)).count == 4)
        #expect(result.profiles[0].id == "a" && result.profiles[3].id == "d")
        #expect(result.profiles.map(\.name) == ["Main", "main 2", "Profile", "MAIN 3"])
        #expect(clamped.contains("profiles[1].id") && clamped.contains("profiles[2].id"))
        #expect(clamped.contains("profiles[1].name") && clamped.contains("profiles[3].name"))
        #expect(ConfigValidator.normalized(result).clamped.isEmpty)
    }

    /// 超长名称截断到 64 字。
    @Test func longNameTruncated() {
        let input = config { $0.name = String(repeating: "长", count: 80) }
        #expect(ConfigValidator.normalized(input).config.profiles[0].name.count == 64)
    }

    /// 非法颜色改回默认；按角色的非法颜色被删除，合法的保留。
    @Test func colors() {
        let input = config {
            $0.overlay.titleColor = "white"; $0.overlay.highlightColor = "#12345"
            $0.highlightColors = ["A": "#00FF00", "B": "red"]
        }
        let (result, clamped) = ConfigValidator.normalized(input)
        let p = result.profiles[0]
        #expect(p.overlay.titleColor == "#FFFFFF" && p.overlay.highlightColor == "#ADFF2F")
        #expect(p.highlightColors == ["A": "#00FF00"])
        #expect(clamped.contains("profiles[0].highlightColors[B]"))
    }

    /// 布局里无法使用的数值被改正；循环组的空或重复 id 换新。
    @Test func layoutsAndGroups() {
        let input = config {
            $0.layouts = ["A": ThumbnailLayout(x: .infinity, y: 5, width: -1, height: 200)]
            $0.cycleGroups = [CycleGroup(id: "g", name: "1"), CycleGroup(id: "g", name: "2"), CycleGroup(id: "", name: "3")]
        }
        let p = ConfigValidator.normalized(input).config.profiles[0]
        #expect(p.layouts["A"] == ThumbnailLayout(x: 0, y: 5, width: nil, height: 200))
        #expect(Set(p.cycleGroups.map(\.id)).count == 3 && p.cycleGroups[0].id == "g")
    }
    /// 循环组成员去重，保留第一次出现的位置；记录字段路径；再校验一次不变（5.4 节）。
    @Test func duplicateMembersRemoved() {
        let input = config {
            $0.cycleGroups = [CycleGroup(id: "g", name: "1", members: ["A", "B", "A", "C", "B"]),
                              CycleGroup(id: "h", name: "2", members: ["X", "Y"])]
        }
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(result.profiles[0].cycleGroups[0].members == ["A", "B", "C"])
        #expect(result.profiles[0].cycleGroups[1].members == ["X", "Y"])
        #expect(clamped == ["profiles[0].cycleGroups[0].members"])
        #expect(ConfigValidator.normalized(result).clamped.isEmpty)
    }

    /// 布局坐标与登录位置夹到 ±100,000 点；范围内的值不变；再校验一次不变。
    @Test func coordinatesClamped() {
        let input = config {
            $0.layouts = ["A": ThumbnailLayout(x: 1e12, y: -1e9, width: nil, height: nil),
                          "B": ThumbnailLayout(x: -99_999, y: 100_000, width: nil, height: nil)]
            $0.loginPosition = ScreenPoint(x: -5e15, y: 2e5)
        }
        let (result, clamped) = ConfigValidator.normalized(input)
        let p = result.profiles[0]
        #expect(p.layouts["A"] == ThumbnailLayout(x: 100_000, y: -100_000, width: nil, height: nil))
        #expect(p.layouts["B"] == ThumbnailLayout(x: -99_999, y: 100_000, width: nil, height: nil))
        #expect(p.loginPosition == ScreenPoint(x: -100_000, y: 100_000))
        #expect(clamped == ["profiles[0].loginPosition", "profiles[0].layouts[A]"])
        #expect(ConfigValidator.normalized(result).clamped.isEmpty)
    }

    /// 截断点落在空白上时，截断后再去一次空白，所以校验两次结果相同。
    @Test func truncatedNameIsIdempotent() {
        let name = String(repeating: "a", count: 63) + "   tail"
        let once = ConfigValidator.normalized(config { $0.name = name })
        #expect(once.config.profiles[0].name == String(repeating: "a", count: 63))
        let twice = ConfigValidator.normalized(once.config)
        #expect(twice.clamped.isEmpty && twice.config == once.config)
        // 加序号的分支：与已有名称重名时，结果同样没有首尾空白，再校验一次不变。
        let input = AppConfig(activeProfileID: "a", profiles: [
            Profile(id: "a", name: String(repeating: "a", count: 63)), Profile(id: "b", name: name),
        ])
        let first = ConfigValidator.normalized(input).config
        #expect(first.profiles[1].name == String(repeating: "a", count: 62) + " 2")
        #expect(ConfigValidator.normalized(first).clamped.isEmpty)
    }
}

// MARK: - 第一轮反馈的校验（反馈文档 3.2 节）

extension ConfigValidatorTests {
    /// 边框粗细、持续时间、最小伤害的下界。
    @Test func round1LowerBounds() {
        let (result, clamped) = ConfigValidator.normalized(config {
            $0.overlay.borderThickness = 0
            $0.combatAlert.durationSeconds = 0.5
            $0.combatAlert.minimumDamage = 0
        })
        let p = result.profiles[0]
        #expect(p.overlay.borderThickness == 1)
        #expect(p.combatAlert.durationSeconds == 1 && p.combatAlert.minimumDamage == 1)
        #expect(Set(clamped) == ["profiles[0].overlay.borderThickness", "profiles[0].combatAlert.durationSeconds",
                                 "profiles[0].combatAlert.minimumDamage"])
    }

    /// 边框粗细、持续时间、最小伤害的上界；持续时间不是有限值时改回默认值。
    @Test func round1UpperBounds() {
        let p = ConfigValidator.normalized(config {
            $0.overlay.borderThickness = 7
            $0.combatAlert.durationSeconds = 10.5
            $0.combatAlert.minimumDamage = 100_001
        }).config.profiles[0]
        #expect(p.overlay.borderThickness == 6)
        #expect(p.combatAlert.durationSeconds == 10 && p.combatAlert.minimumDamage == 100_000)
        let nan = ConfigValidator.normalized(config { $0.combatAlert.durationSeconds = .nan }).config.profiles[0]
        #expect(nan.combatAlert.durationSeconds == 3.0)
    }

    /// 恰好在边界上的值原样保留。
    @Test func round1ExactBoundsKept() {
        for (thickness, duration, damage) in [(1, 1.0, 1), (6, 10.0, 100_000)] {
            let (result, clamped) = ConfigValidator.normalized(config {
                $0.overlay.borderThickness = thickness
                $0.combatAlert.durationSeconds = duration
                $0.combatAlert.minimumDamage = damage
            })
            #expect(clamped.isEmpty)
            #expect(result.profiles[0].overlay.borderThickness == thickness)
        }
    }

    /// 边框颜色与提醒颜色不是合法的 #RRGGBB 时改回默认值；合法值保留。
    @Test func round1Colors() {
        let (result, clamped) = ConfigValidator.normalized(config {
            $0.overlay.borderColor = "grey"
            $0.combatAlert.color = "#12345"
        })
        let p = result.profiles[0]
        #expect(p.overlay.borderColor == "#C0C0C0" && p.combatAlert.color == "#FF3B30")
        #expect(Set(clamped) == ["profiles[0].overlay.borderColor", "profiles[0].combatAlert.color"])
        let valid = ConfigValidator.normalized(config {
            $0.overlay.borderColor = "#00aa00"
            $0.combatAlert.color = "#ABCDEF"
        })
        #expect(valid.clamped.isEmpty && valid.config.profiles[0].overlay.borderColor == "#00aa00")
    }

    /// 游戏日志目录是空白串时变成 nil；非空的路径原样保留。
    @Test func eveLogDirectoryBlankBecomesNil() {
        var blank = config { _ in }
        blank.general.eveLogDirectory = "  \n"
        let (result, clamped) = ConfigValidator.normalized(blank)
        #expect(result.general.eveLogDirectory == nil)
        #expect(clamped == ["general.eveLogDirectory"])
        var empty = config { _ in }
        empty.general.eveLogDirectory = ""
        #expect(ConfigValidator.normalized(empty).config.general.eveLogDirectory == nil)
        var path = config { _ in }
        path.general.eveLogDirectory = "~/EVE/logs"
        let kept = ConfigValidator.normalized(path)
        #expect(kept.clamped.isEmpty && kept.config.general.eveLogDirectory == "~/EVE/logs")
    }

    /// `logLevel` 是 notice、error、fault 时改回 info，并记下字段路径（v1.1 设计 3.1 节）。
    @Test(arguments: [LogLevel.notice, .error, .fault])
    func unsupportedLogLevelBecomesInfo(level: LogLevel) {
        var input = config { _ in }
        input.general.logLevel = level
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(result.general.logLevel == .info)
        #expect(clamped == ["general.logLevel"])
    }

    /// info 与 debug 原样保留。
    @Test(arguments: [LogLevel.info, .debug])
    func supportedLogLevelKept(level: LogLevel) {
        var input = config { _ in }
        input.general.logLevel = level
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(result.general.logLevel == level && clamped.isEmpty)
    }

    /// 「自动安装」打开而「自动检查」关闭时不改值（界面置灰，行为按不检查处理）。
    @Test func autoInstallWithoutCheckIsKept() {
        var input = config { _ in }
        input.general.checkForUpdates = false
        input.general.autoInstallUpdates = true
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(!result.general.checkForUpdates && result.general.autoInstallUpdates)
        #expect(clamped.isEmpty)
    }
}

/// 预警与翻译设置的校验（docs/macos/design-intel-translate.md 3.2 节的 7 条规则）。频道名是虚构的。
struct ChatConfigValidatorTests {
    /// 只含一个配置方案的配置，便于修改后校验。
    private func config(_ edit: (inout Profile) -> Void) -> AppConfig {
        var profile = Profile(id: "p1", name: "Main")
        edit(&profile)
        return AppConfig(activeProfileID: "p1", profiles: [profile])
    }

    /// 第 1 条：整数与小数的下界、上界；非有限值改回默认值。
    @Test func ranges() {
        let low = ConfigValidator.normalized(config {
            $0.intel.windowMinutes = 1; $0.intel.maxJumps = 0; $0.intel.alertJumps = -1
            $0.intel.overlay.opacity = 0.1; $0.intel.overlay.fontSize = 2
        })
        let lp = low.config.profiles[0].intel
        #expect(lp.windowMinutes == 5 && lp.maxJumps == 1 && lp.alertJumps == 0)
        #expect(lp.overlay.opacity == 0.2 && lp.overlay.fontSize == 10)
        #expect(low.clamped.contains("profiles[0].intel.windowMinutes"))
        #expect(low.clamped.contains("profiles[0].intel.overlay.opacity"))
        let high = ConfigValidator.normalized(config {
            $0.intel.windowMinutes = 500; $0.intel.maxJumps = 99; $0.intel.alertJumps = 99
            $0.translation.overlay.opacity = 3; $0.translation.overlay.fontSize = 99
        })
        let hp = high.config.profiles[0]
        #expect(hp.intel.windowMinutes == 120 && hp.intel.maxJumps == 30 && hp.intel.alertJumps == 30)
        #expect(hp.translation.overlay.opacity == 1.0 && hp.translation.overlay.fontSize == 24)
        let nan = ConfigValidator.normalized(config {
            $0.intel.overlay.opacity = .nan; $0.translation.overlay.fontSize = .infinity
        }).config.profiles[0]
        #expect(nan.intel.overlay.opacity == 0.75 && nan.translation.overlay.fontSize == 12)
        let exact = config { $0.intel.windowMinutes = 5; $0.intel.maxJumps = 30; $0.intel.alertJumps = 0 }
        #expect(ConfigValidator.normalized(exact).clamped.isEmpty)
    }

    /// 第 2 条：alertJumps 大于 maxJumps 时改成 maxJumps（maxJumps 先夹到范围内）。
    @Test func alertJumpsCappedByMaxJumps() {
        let result = ConfigValidator.normalized(config { $0.intel.maxJumps = 4; $0.intel.alertJumps = 9 })
        #expect(result.config.profiles[0].intel.alertJumps == 4)
        #expect(result.clamped == ["profiles[0].intel.alertJumps"])
        let both = ConfigValidator.normalized(config { $0.intel.maxJumps = 0; $0.intel.alertJumps = 5 })
        #expect(both.config.profiles[0].intel.maxJumps == 1 && both.config.profiles[0].intel.alertJumps == 1)
    }

    /// 第 3 条：去名字的首尾空白、空白 id 改成 nil、空项删除、两种情形的去重、至多 16 项。
    @Test func channels() {
        let input = config {
            $0.intel.channels = [
                ChannelRef(name: "  intel.Demo ", id: "player_1"),
                ChannelRef(name: "renamed", id: "player_1"),          // id 相同：重复
                ChannelRef(name: "chat.Demo", id: ""),                // 空 id 改成 nil
                ChannelRef(name: "CHAT.demo"),                        // 都没有 id、名字相同：重复
                ChannelRef(name: "   ", id: nil),                     // 名字与 id 都空：删除
                ChannelRef(name: "chat.Demo", id: "player_2"),        // 有 id：不与只有名字的项去重
            ]
        }
        let (result, clamped) = ConfigValidator.normalized(input)
        #expect(result.profiles[0].intel.channels == [ChannelRef(name: "intel.Demo", id: "player_1"),
                                                      ChannelRef(name: "chat.Demo"),
                                                      ChannelRef(name: "chat.Demo", id: "player_2")])
        #expect(clamped == ["profiles[0].intel.channels"])
        let many = config { $0.translation.channels = (1...20).map { ChannelRef(name: "c\($0)") } }
        let trimmed = ConfigValidator.normalized(many).config.profiles[0].translation.channels
        #expect(trimmed.count == IntelSettings.maxChannels && trimmed.last?.name == "c16")
    }

    /// 第 4 条：id 以 private_ 开头的项删除。
    @Test func privateChannelsRemoved() {
        let input = config { $0.translation.channels = [ChannelRef(name: "Mira Voss", id: "private_9"), .local] }
        #expect(ConfigValidator.normalized(input).config.profiles[0].translation.channels == [.local])
    }

    /// 校验不管 resolvePilotNames（6.9 节）：false 校验后仍是 false，也不记为改动。
    @Test func resolvePilotNamesUntouched() {
        let result = ConfigValidator.normalized(config { $0.intel.resolvePilotNames = false })
        #expect(!result.config.profiles[0].intel.resolvePilotNames && result.clamped.isEmpty)
    }

    /// 第 5 条：空白的参考星系改成 nil；非空的原样保留。
    @Test func referenceSystem() {
        #expect(ConfigValidator.normalized(config { $0.intel.referenceSystem = "  " })
                .config.profiles[0].intel.referenceSystem == nil)
        let kept = ConfigValidator.normalized(config { $0.intel.referenceSystem = " Jita" })
        #expect(kept.config.profiles[0].intel.referenceSystem == " Jita" && kept.clamped.isEmpty)
    }

    /// 第 6 条：宽或高不是有限的正数时 frame 改成 nil；正常的 frame 不动。
    @Test func overlayFrame() {
        let bad = [ScreenRect(x: 0, y: 0, width: 0, height: 100), ScreenRect(x: 0, y: 0, width: 100, height: -1),
                   ScreenRect(x: 0, y: 0, width: .infinity, height: 100), ScreenRect(x: .nan, y: 0, width: 1, height: 1)]
        for frame in bad {
            let result = ConfigValidator.normalized(config { $0.intel.overlay.frame = frame })
            #expect(result.config.profiles[0].intel.overlay.frame == nil)
            #expect(result.clamped == ["profiles[0].intel.overlay.frame"])
        }
        let good = ScreenRect(x: -500, y: 20, width: 380, height: 260)
        #expect(ConfigValidator.normalized(config { $0.translation.overlay.frame = good })
                .config.profiles[0].translation.overlay.frame == good)
    }

    /// 第 7 条：接口地址与模型名去掉首尾空白，地址末尾的 `/` 全部去掉；结果再校验一次不变。
    @Test func endpoint() {
        var input = config { _ in }
        input.general.translationEndpoint = TranslationEndpointSettings(provider: .custom,
                                                                        baseURL: "  https://h.example/v1// ",
                                                                        model: " m ")
        let once = ConfigValidator.normalized(input)
        #expect(once.config.general.translationEndpoint.baseURL == "https://h.example/v1")
        #expect(once.config.general.translationEndpoint.model == "m")
        #expect(once.clamped == ["general.translationEndpoint.baseURL", "general.translationEndpoint.model"])
        #expect(ConfigValidator.normalized(once.config).clamped.isEmpty)
    }
}
