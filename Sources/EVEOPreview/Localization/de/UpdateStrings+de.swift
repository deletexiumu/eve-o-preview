// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的德文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表：更新 Update、„Nach Updates suchen …“（macOS 德文版的说法）、
// 发布说明 Neuerungen、„Update installieren“、„Diese Version überspringen“、„Später“、签名 Signatur；
// 窗口标题取 macOS 德文的 Softwareupdate，缩略图 Miniatur（反馈文档 5.5 节）。
// 「重新启动」与现有的权限页一致写 neu starten；「应用程序」文件夹写 „Programme“（macOS 德文版的名称），
// 引号用 „…“；磁盘写 Volume，磁盘映像写 Festplattenimage（均为 macOS 德文的说法）。
// 本域的文字不带数量，不用处理复数；需要用户动手的地方写成不定式，不称呼用户。

import Foundation

/// 更新域的德文实现。
struct UpdateStringsDE: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "Nach Updates suchen …" }
    func menuUpdateAvailable(_ version: String) -> String { "Update verfügbar: \(version) …" }
    func menuRestartToUpdate(_ version: String) -> String { "Neu starten und auf \(version) aktualisieren" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "Updates" }
    var autoCheckToggle: String { "Automatisch nach Updates suchen" }
    var autoCheckHelp: String { "Kontaktiert GitHub einmal täglich. Es werden keine persönlichen Daten gesendet." }
    var autoInstallToggle: String { "Updates automatisch installieren" }
    var autoInstallHelp: String {
        "Lädt im Hintergrund. Installiert und startet neu, wenn seit einer Minute kein EVE-Client mehr läuft, "
            + "oder installiert beim Beenden von EVE-O Preview."
    }
    var currentVersionLabel: String { "Aktuelle Version" }
    var lastCheckedLabel: String { "Zuletzt geprüft" }
    var lastCheckedNever: String { "Nie" }
    var checkNowButton: String { "Jetzt suchen" }

    // MARK: 状态行

    var statusChecking: String { "Suche läuft …" }
    var statusUpToDate: String { "EVE-O Preview ist auf dem neuesten Stand." }
    func statusAvailable(_ version: String) -> String { "Version \(version) ist verfügbar." }
    func statusReady(_ version: String) -> String {
        "Version \(version) ist geladen. Die Installation erfolgt, wenn kein EVE-Client läuft, oder beim Beenden."
    }
    // 时刻已按德文格式化（如 14:05），接在 ab 后面。
    func statusRateLimited(_ time: String) -> String { "GitHub begrenzt Anfragen. Neuer Versuch ab \(time) möglich." }
    var statusRateLimitedLater: String { "GitHub begrenzt Anfragen. Später erneut versuchen." }
    var statusUnavailable: String { "Updates sind in diesem Build nicht verfügbar." }

    // MARK: 更新窗口

    var windowTitle: String { "Softwareupdate" }
    func headline(_ version: String) -> String { "EVE-O Preview \(version) ist verfügbar" }
    // 「你装的是 X」改写成「已安装：X」的句式，不称呼用户。
    func currentVersionLine(_ version: String) -> String { "Installiert ist Version \(version)." }
    var releaseNotesHeader: String { "Neuerungen" }
    var installButton: String { "Update installieren" }
    var installHelp: String {
        "Die App startet nach der Installation neu. Die Miniaturen verschwinden für einige Sekunden."
    }
    var skipButton: String { "Diese Version überspringen" }
    var laterButton: String { "Später" }
    var openReleasePageButton: String { "Release-Seite öffnen" }
    var cancelButton: String { "Abbrechen" }
    var closeButton: String { "Schließen" }
    var retryButton: String { "Erneut versuchen" }
    // 两个大小已按德文格式化（如「1,2 MB」）。
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "Wird geladen … \(received) von \($0)" } ?? "Wird geladen … \(received)"
    }
    var progressVerifying: String { "Wird überprüft …" }
    var progressInstalling: String { "Wird installiert …" }
    var progressRelaunching: String { "Wird neu gestartet …" }
    // 使用测试地址（EVEO_UPDATE_FEED_URL）时的标记。
    var testFeedBadge: String { "Testquelle" }
    var notifyOnlyIntro: String { "Diese Kopie kann sich nicht selbst aktualisieren." }
    var currentVersionUnchanged: String { "Die aktuelle Version bleibt unverändert." }
    var reopenManually: String { "Das Update ist installiert. EVE-O Preview beenden und erneut öffnen." }

    // MARK: 不能自动安装的原因

    var blockerTranslocated: String {
        "macOS führt die App von einem temporären, schreibgeschützten Ort aus. "
            + "Die App in den Ordner „Programme“ bewegen und erneut öffnen."
    }
    var blockerUnsupportedVolume: String {
        "Die App liegt auf einem Volume, das nicht mit APFS formatiert ist, daher können Updates nicht in der App "
            + "installiert werden. Die neue Version von der Release-Seite laden."
    }
    var blockerReadOnlyVolume: String {
        "Die App liegt auf einem schreibgeschützten Volume. Zuerst in den Ordner „Programme“ kopieren."
    }
    var blockerLocationNotWritable: String { "Keine Berechtigung, den Ordner mit der App zu ändern." }
    // Build 保留英文，按德文开发者的习惯作阳性名词（der Build）。
    var blockerAdHocSignature: String {
        "Dieser Build hat keine stabile Signatur, daher kann eine neue Version nicht damit abgeglichen werden."
    }
    var blockerDevelopmentSignature: String { "Dies ist ein lokal signierter Entwicklungs-Build." }
    var blockerUnsigned: String { "Dieser Build ist nicht signiert." }

    // MARK: 错误

    var errorNetwork: String { "GitHub ist nicht erreichbar. Internetverbindung prüfen." }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub hat mit einem Fehler geantwortet (\(code))." }
    var errorMalformedFeed: String { "Die Release-Informationen konnten nicht gelesen werden." }
    var errorAssetMissing: String { "Dieses Release enthält kein Installationsprogramm für automatische Updates." }
    var errorDiskSpace: String { "Nicht genug freier Speicherplatz für den Download." }
    var errorChecksum: String { "Der Download stimmt nicht mit seiner Prüfsumme überein und wurde verworfen." }
    var errorDiskImage: String { "Das geladene Festplattenimage konnte nicht geöffnet werden." }
    var errorVerification: String {
        "Die neue Version konnte nicht überprüft werden und wurde daher nicht installiert."
    }
    func errorUnsupportedSystem(_ minimum: String) -> String { "Diese Version erfordert macOS \(minimum) oder neuer." }
    var errorSwapFailed: String { "Die App konnte nicht ersetzt werden." }
}
