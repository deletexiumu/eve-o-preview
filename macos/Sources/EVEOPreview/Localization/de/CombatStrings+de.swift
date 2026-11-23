// SPDX-License-Identifier: GPL-3.0-or-later
//
// 「提醒」页的德文文字（反馈文档 5.3 节、7.11 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 5.5 节的词表：战斗提醒 Kampfwarnung、游戏日志 Spielprotokoll、缩略图 Miniatur；
// 系统权限用 macOS 德文界面的「Dateien und Ordner」，「文稿」文件夹是「Dokumente」，引号用 „…“。
// 德文与英文一样只区分单数与复数，文件数在 statusWatching 里直接判断；秒数的小数点换成逗号。

import Foundation

/// 「提醒」页的德文文字。
struct CombatStringsDE: CombatStrings {
    // MARK: 页头
    var pageSubtitle: String { "Die Miniatur eines Charakters blinkt, wenn er angegriffen wird." }

    // MARK: 开关与状态行
    // 状态行显示目录全路径，文字保持短。
    var enableToggle: String { "Miniatur bei Angriff auf einen Charakter blinken lassen" }
    var statusLabel: String { "Status" }
    var statusStopped: String { "Aus" }
    func statusWatching(directory: String, files: Int) -> String {
        "Überwacht \(files == 1 ? "1 Protokolldatei" : "\(files) Protokolldateien") in \(directory)"
    }
    func statusDirectoryNotFound(_ path: String) -> String { "Ordner der Spielprotokolle nicht gefunden: \(path)" }
    func statusAccessDenied(_ path: String) -> String { "Keine Leseberechtigung für \(path)" }
    // 不定式句，不称呼用户；路径按系统设置里的层级写全。
    var accessDeniedHelp: String {
        "EVE-O Preview unter „Systemeinstellungen > Datenschutz & Sicherheit > Dateien und Ordner“ "
            + "den Zugriff auf den Ordner „Dokumente“ erlauben."
    }
    var openSystemSettings: String { "Systemeinstellungen öffnen …" }

    // MARK: 日志目录
    var logDirectoryHeader: String { "Spielprotokolle" }
    var logDirectoryLabel: String { "Ordner" }
    var automaticSuffix: String { "(automatisch)" }
    var chooseDirectory: String { "Auswählen …" }
    var useAutomaticLocation: String { "Automatischen Ort verwenden" }
    // 文件夹名 logs、Gamelogs 是 EVE 客户端写死的目录名，不翻译。
    var chooseDirectoryMessage: String { "Den EVE-Ordner „logs“ oder „Gamelogs“ auswählen." }

    // MARK: 闪烁的外观
    var appearanceHeader: String { "Blinken" }
    var flashColor: String { "Blinkfarbe" }
    var duration: String { "Dauer" }
    /// 共用的数字部分用英文小数点，德文换成逗号（如「3,5 s」）。
    func seconds(_ value: Double) -> String {
        combatSecondsNumber(value).replacingOccurrences(of: ".", with: ",") + " s"
    }
    var style: String { "Stil" }
    var styleBorder: String { "Rahmen" }
    // 「底色」指整张缩略图罩一层颜色，德文用 Tönung（着色）。
    var styleWash: String { "Tönung" }
    var styleBoth: String { "Beides" }

    // MARK: 触发条件
    var triggersHeader: String { "Auslöser" }
    var includeMisses: String { "Auch bei verfehlten Angriffen warnen" }
    var minimumDamage: String { "Mindestschaden" }
    var minimumDamageHelp: String {
        "Treffer unter diesem Wert werden ignoriert. Für Fehlschüsse gilt der Schalter oben."
    }

    // MARK: 测试与说明
    var testFlash: String { "Blinken testen" }
    var testFlashHelp: String { "Lässt jede Miniatur einmal blinken, auch wenn die Warnung aus ist." }
    var footnote: String {
        "Der EVE-Client muss Spielnachrichten in Protokolldateien schreiben. "
            + "Diese Funktion liest nur die Spielprotokolle und sendet nie Eingaben an das Spiel."
    }
}
