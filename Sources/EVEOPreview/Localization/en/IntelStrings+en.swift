// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警域的英文文字（docs/design-intel-translate.md 第 11 节）。用词按第 11 节的词表：overlay、intel、channel、
// jump、hostile、chat log、map data、name check；ESI 不翻译。英文复数按数量取单复数形式。

import Foundation

/// 单复数：1 用单数，其余用复数。
private func englishPlural(_ count: Int, _ singular: String, _ plural: String) -> String {
    abs(count) == 1 ? singular : plural
}

/// 预警域的英文文字。
struct IntelStringsEN: IntelStrings {
    // MARK: 页头、开关与频道
    var pageSubtitle: String { "Reads intel channel logs and shows where hostiles are, how many, what ships, and how far." }
    var enableToggle: String { "Show intel overlay" }
    var statusLabel: String { "Status" }
    var channelsHelp: String { "Choose the channels where hostiles are reported." }

    // MARK: 我的位置
    var locationHeader: String { "My Location" }
    var locationHelp: String {
        "Location comes from jump records in the game log and from the Local channel log. "
            + "Enter it here when neither is available."
    }
    var locationUnknown: String { "Unknown" }
    func locationValue(system: String, source: String, age: String) -> String { "\(system) (\(source), \(age) ago)" }
    var sourceGameLog: String { "game log" }
    var sourceLocal: String { "Local channel" }
    var sourceManual: String { "manual" }
    var systemPlaceholder: String { "Type a system name and press Return" }
    var clearLocation: String { "Clear" }
    var systemNotFound: String { "System not found" }
    var noOnlineCharacters: String { "No characters online" }
    var referenceSystem: String { "Reference System" }
    var referenceSystemHelp: String {
        "Jumps are counted from the reference system when a character's location is unknown."
    }

    // MARK: 显示
    var displayHeader: String { "Display" }
    var windowMinutes: String { "Keep the last" }
    func minutes(_ count: Int) -> String { "\(count) min" }
    var maxJumps: String { "Count up to" }
    func jumpsUnit(_ count: Int) -> String { "\(count) \(englishPlural(count, "jump", "jumps"))" }
    var alertJumps: String { "Highlight Within" }
    var alertJumpsHelp: String {
        "Reports within this many jumps are highlighted. Set to 0 to turn highlighting off."
    }
    var showOriginal: String { "Show original text" }

    // MARK: 星图数据与页尾
    var staticDataLabel: String { "Map Data" }
    func staticDataBuild(_ build: Int) -> String { "SDE build \(build)" }
    var staticDataMissing: String { "Map data is missing; systems and ships cannot be recognized" }
    var footnote: String {
        "This feature only reads chat logs and game logs and sends no input to the game. "
            + "Pilot names and counts are inferred from message format and may be wrong. "
            + "Online name checking only shows that a character with that name exists, "
            + "not that the message refers to that character."
    }

    // MARK: 浮窗的标题与状态行
    func overlayTitle(_ character: String) -> String { "Intel · \(character)" }
    var statusNoStaticData: String { "Map data missing" }
    var statusNoChannels: String { "No intel channels set" }
    var statusLocationUnknown: String { "Location unknown; right-click to open settings" }
    func statusUsingReference(_ system: String) -> String { "Location unknown; counting from \(system)" }
    func statusLocation(system: String, source: String, age: String) -> String {
        "Location: \(system) (\(source), \(age) ago)"
    }

    // MARK: 浮窗每一行
    func ageSeconds(_ count: Int) -> String { "\(count)s" }
    func ageMinutes(_ count: Int) -> String { "\(count)m" }
    func jumps(_ count: Int) -> String { "\(count)j" }
    var jumpsHere: String { "here" }
    func jumpsBeyond(_ limit: Int) -> String { ">\(limit)j" }
    var jumpsUnreachable: String { "no gates" }
    var jumpsUnknown: String { "?" }
    func count(_ value: Int) -> String { "×\(value)" }
    func countInferred(_ value: Int) -> String { "~×\(value)" }
    var clear: String { "clear" }
    var noVisual: String { "no visual" }

    // MARK: 人名核对
    var resolvePilotsToggle: String { "Check pilot names online (ESI)" }
    var resolvePilotsHelp: String {
        "When several names with spaces run together, asks CCP's ESI API which characters they are. "
            + "Only those words are sent, not the speaker, the channel name, or your character names. "
            + "Single-word names are not looked up."
    }
    var pilotLookupLabel: String { "Name Check" }
    func pilotLookupIdle(_ count: Int) -> String {
        "Ready, \(count) character \(englishPlural(count, "name", "names")) saved"
    }
    var pilotLookupResolving: String { "Checking" }
    func pilotLookupWaiting(_ seconds: Int) -> String { "ESI is unavailable; retrying in \(seconds)s" }
    var clearPilotCache: String { "Clear Name Cache" }
    func pilotCacheCount(_ count: Int) -> String {
        "\(count) character \(englishPlural(count, "name", "names")) saved"
    }
}
