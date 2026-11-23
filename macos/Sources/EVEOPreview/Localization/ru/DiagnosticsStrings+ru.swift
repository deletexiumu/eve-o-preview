// SPDX-License-Identifier: GPL-3.0-or-later
//
// 诊断域的俄文文字（v1.1 设计 11.4 节）。
// 译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 用词按 11.3 节的词表：отчёт、отчёт о сбое、журнал、заполнитель；菜单项「报告问题…」用 «Сообщить о проблеме…»。
// 俄文的复数有 3 种形式，由 replacements 处理。

import Foundation

/// 诊断域的俄文文字。
struct DiagnosticsStringsRU: DiagnosticsStrings {
    // MARK: 菜单栏菜单
    var menuReportProblem: String { "Сообщить о проблеме…" }
    var menuCrashPending: String { "EVE-O Preview неожиданно завершилась — Сообщить…" }

    // MARK: 「通用」页的诊断一组
    var sectionHeader: String { "Диагностика" }
    var verboseLoggingToggle: String { "Подробный журнал" }
    var verboseLoggingHelp: String {
        "Записывает в файл журнала больше подробностей. Включите перед тем, как воспроизвести проблему."
    }
    var logLocationLabel: String { "Файлы журнала" }
    var showLogsButton: String { "Показать журналы в Finder" }
    var reportButton: String { "Сообщить о проблеме…" }

    // MARK: 报告窗口的说明
    var windowTitle: String { "Сообщить о проблеме" }
    var intro: String {
        "Будет создан zip-файл с перечисленными ниже элементами. Ничего не отправляется автоматически: "
            + "вы сами прикрепляете файл к issue на GitHub."
    }
    var crashIntro: String {
        "В прошлый раз EVE-O Preview неожиданно завершилась. Отчёт поможет найти причину."
    }
    var redactionNote: String {
        "Имя пользователя macOS, имя компьютера и имена персонажей EVE заменены заполнителями."
    }

    // MARK: 报告窗口的文件列表与预览
    var itemsHeader: String { "Содержимое отчёта" }
    var itemSummary: String { "Сводка об окружении" }
    var itemConfig: String { "Сводка настроек (без имён)" }
    var itemLog: String { "Журнал приложения" }
    func itemCrash(_ number: Int) -> String { "Отчёт о сбое \(number)" }
    var itemManifest: String { "Список файлов" }
    var previewTruncated: String { "Показано только начало. В отчёт входит весь файл." }
    func replacements(_ count: Int) -> String { "\(count) \(replacementWord(count))" }
    var collecting: String { "Сбор данных…" }

    // MARK: 报告窗口的按钮
    var createAndOpenButton: String { "Создать отчёт и открыть GitHub" }
    var createOnlyButton: String { "Только создать отчёт" }
    var cancelButton: String { "Отменить" }
    var notNowButton: String { "Не сейчас" }
    var dontReportButton: String { "Не сообщать" }

    // MARK: 完成页
    var doneTitle: String { "Отчёт создан" }
    var doneHelp: String {
        "В Finder выделен zip-файл. Перетащите его на страницу issue в браузере, опишите, что произошло, "
            + "и отправьте."
    }
    var revealButton: String { "Показать в Finder" }
    var openIssueButton: String { "Снова открыть GitHub" }
    var closeButton: String { "Закрыть" }

    // MARK: 错误
    func createFailed(_ reason: String) -> String { "Не удалось создать отчёт: \(reason)" }

    // MARK: 复数
    /// «замена» в нужной форме: 1 замена, 2–4 замены, 5–20 замен.
    private func replacementWord(_ count: Int) -> String {
        let lastTwo = abs(count) % 100
        let last = abs(count) % 10
        if (11...14).contains(lastTwo) { return "замен" }
        switch last {
        case 1: return "замена"
        case 2...4: return "замены"
        default: return "замен"
        }
    }
}
