// SPDX-License-Identifier: GPL-3.0-or-later
//
// 浮窗域的德文文字（docs/macos/design-intel-translate.md 第 11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词与菜单栏一致：Overlay、Kanal、„Layout sperren“。德文只区分单数与复数。

import Foundation

/// 浮窗与两页共用设置控件的德文文字。
struct OverlayStringsDE: OverlayStrings {
    // MARK: 浮窗的列表
    func newMessages(_ count: Int) -> String { "\(count) neu" }
    var noActiveCharacter: String { "Kein Charakter im aktuellen Fenster" }
    var emptyList: String { "Noch keine Nachrichten" }

    // MARK: 浮窗的右键菜单
    var menuScrollToLatest: String { "Zum Neuesten scrollen" }
    var menuCopyLine: String { "Diese Zeile kopieren" }
    var menuOpenInBrowser: String { "Im Browser öffnen" }
    var menuClear: String { "Liste leeren" }
    var menuLockLayout: String { "Layout sperren" }
    var menuResetFrame: String { "Position und Größe zurücksetzen" }
    var menuHide: String { "Dieses Overlay ausblenden" }
    var menuOpenSettings: String { "Einstellungen öffnen …" }

    // MARK: 浮窗设置
    var overlayHeader: String { "Overlay" }
    var opacity: String { "Deckkraft des Hintergrunds" }
    var fontSize: String { "Schriftgröße" }
    var resetFrame: String { "Position zurücksetzen" }
    var gestureHelp: String { "Mit der rechten Maustaste oder mit Wahltaste und linker Maustaste ziehen, um das Overlay zu bewegen; den Zeiger an den Rand bewegen und mit der linken Maustaste ziehen, um die Größe zu ändern; scrollen, um die Liste zu durchblättern." }
    var visibilityLabel: String { "Anzeigen" }
    var visibilityAlways: String { "Immer" }
    var visibilityGameOnly: String { "Nur in EVE: ausblenden, wenn kein EVE-Fenster im Vordergrund ist" }
    var positionLabel: String { "Position" }
    var sizeLabel: String { "Größe" }
    var frameHelp: String { "Die Position wird in Punkten ab der linken oberen Ecke des Hauptbildschirms angegeben. Die Größe ist auf 220×120 bis 900×900 begrenzt; eine Position außerhalb des Bildschirms wird zurückgeholt." }

    // MARK: 频道列表
    var channelsHeader: String { "Kanäle" }
    var addFromLogs: String { "Aus Protokollen hinzufügen" }
    var addByNamePlaceholder: String { "Kanalnamen eingeben und Zeilenschalter drücken" }
    var removeChannel: String { "Entfernen" }
    var noChannels: String { "Noch keine Kanäle" }
    var refreshChannels: String { "Aktualisieren" }
    var noDiscoveredChannels: String { "Keine aktuellen Chatprotokolle gefunden" }
    func channelListeners(_ count: Int) -> String { count == 1 ? "1 Charakter" : "\(count) Charaktere" }

    // MARK: 内置频道
    var builtInLocal: String { "Lokal" }
    var builtInCorp: String { "Corporation" }
    var builtInAlliance: String { "Allianz" }
    var builtInFleet: String { "Flotte" }
}
