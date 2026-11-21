// SPDX-License-Identifier: GPL-3.0-or-later
//
// 俄文界面文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与英文文件一致，每条的用途见协议里的注释（Strings.swift、SettingsStrings.swift）。
//
// 用词的依据：
// - 反馈文档 5.5 节的词表：миниатюра、клиент、профиль、группа переключения、рамка、подсветка 等。
// - EVE 俄文客户端的叫法：角色是 персонаж，登录界面是 экран входа。
// - macOS 俄文的官方名称：「编辑」菜单各项取 AppKit 的 MenuCommands.loctable；权限名取系统设置
//   （Запись экрана、Универсальный доступ），「系统设置 > 隐私与安全性」是
//   «Системные настройки» > «Конфиденциальность и безопасность»，访达保留 Finder。
// - 「最小化」写 свернуть（Windows 与游戏玩家的通行说法）；macOS 菜单里的 «Убрать в Dock» 不适合指 EVE 客户端。
// - 引号用俄文的书名号 «»。
// 俄文普遍比英文长；侧栏的页名称只有约 140 点宽，所以用单个词（如 «Миниатюры»、«Переключение»）。

import Foundation
import EVEOPreviewCore

/// 俄文的复数形式。俄文按数字的末位选 3 种形式之一：1（不含 11）用 one，2～4（不含 12～14）用 few，其余用 many。
private func russianPlural(_ count: Int, one: String, few: String, many: String) -> String {
    let lastTwo = abs(count) % 100
    let last = abs(count) % 10
    if (11...14).contains(lastTwo) { return many }
    if last == 1 { return one }
    if (2...4).contains(last) { return few }
    return many
}

// MARK: - 菜单栏

/// 菜单栏菜单，俄文。
struct MenuStringsRU: MenuStrings {
    var showAll: String { "Показать все миниатюры" }
    var hideAll: String { "Скрыть все миниатюры" }
    var profiles: String { "Профили" }
    var minimizeAll: String { "Свернуть все клиенты" }
    var settings: String { "Настройки…" }
    var quit: String { "Завершить EVE-O Preview" }
    var permissionsMissing: String { "Не хватает разрешений…" }
    var fakeMode: String { "Демо-режим (фиктивные клиенты)" }
    var noClients: String { "Клиенты EVE не найдены" }
    func resumeCapture(_ title: String) -> String { "Возобновить захват: \(title)" }
    // 1 клиент, 2 клиента, 5 клиентов, 11 клиентов, 21 клиент。
    func clientCount(_ count: Int) -> String {
        "\(count) " + russianPlural(count, one: "клиент", few: "клиента", many: "клиентов")
    }
}

// MARK: - 编辑菜单

/// 主菜单「编辑」菜单，俄文。全部取 macOS 俄文的菜单名。
struct EditMenuStringsRU: EditMenuStrings {
    var title: String { "Правка" }
    var undo: String { "Отменить" }
    var redo: String { "Повторить" }
    var cut: String { "Вырезать" }
    var copy: String { "Скопировать" }
    var paste: String { "Вставить" }
    var selectAll: String { "Выбрать все" }
    var closeWindow: String { "Закрыть окно" }
}

// MARK: - 缩略图

/// 缩略图的右键菜单与占位文字，俄文。
struct ThumbnailStringsRU: ThumbnailStrings {
    var minimize: String { "Свернуть" }
    var minimizeAll: String { "Свернуть все" }
    var skipCycle: String { "Пропускать при переключении" }
    var hide: String { "Скрыть эту миниатюру" }
    var resetSize: String { "Вернуть размер по умолчанию" }
    var resumeCapture: String { "Возобновить захват" }
    var needsAccessibility: String { "Нужен Универсальный доступ" }
    func unavailable(_ item: String, reason: String) -> String { "\(item) (\(reason))" }
    var settings: String { "Настройки…" }
    // 占位文字：缩略图很小，尽量短。
    var waiting: String { "Ожидание изображения…" }
    var needsScreenRecording: String { "Нет разрешения «Запись экрана»" }
    var captureStopped: String { "Захват остановлен. Щелкните правой кнопкой, чтобы возобновить." }
    var minimized: String { "Свернуто" }
}

// MARK: - 设置窗口

/// 设置窗口，俄文。单位用俄文缩写：пт（点）、с（秒）、кадр/с（帧每秒）、мс（毫秒）。
struct SettingsStringsRU: SettingsStrings {
    // 窗口与通用。
    var windowTitle: String { "Настройки EVE-O Preview" }
    var points: String { "пт" }
    var reset: String { "Сбросить" }
    var defaultColor: String { "По умолчанию" }
    var cancel: String { "Отменить" }
    var confirm: String { "OK" }
    var delete: String { "Удалить" }
    var online: String { "В сети" }
    var offline: String { "Не в сети" }
    var forward: String { "Вперед" }
    var backward: String { "Назад" }
    /// 俄文的小数点是逗号（如「1,5 с」），用 ru 区域的数字格式，不用 `String(format:)` 的英文小数点。
    func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "ru"))) + " с"
    }
    func fps(_ value: Double) -> String { String(format: "%.0f кадр/с", value) }
    func milliseconds(_ value: Double) -> String { String(format: "%.0f мс", value) }
    var fakeModeNotice: String {
        "Демо-режим: миниатюры показывают фиктивные клиенты. Переключение и сворачивание меняют только демонстрационные данные."
    }
    func newerSchemaNotice(found: Int, supported: Int) -> String {
        "Файл конфигурации имеет версию \(found), а эта сборка поддерживает версии до \(supported). "
            + "Используются настройки по умолчанию; изменения не будут сохранены."
    }
    func loadFailedNotice(_ message: String) -> String {
        "Не удалось прочитать файл конфигурации (\(message)). "
            + "Используются настройки по умолчанию; изменения не будут сохранены."
    }
    func quarantinedNotice(_ path: String) -> String {
        "Файл конфигурации был поврежден и перемещен в \(path). Используются настройки по умолчанию."
    }
    func configFileFailure(_ operation: ConfigFileOperation, path: String, reason: String) -> String {
        switch operation {
        case .read: return "не удалось прочитать \(path): \(reason)"
        case .write: return "не удалось записать \(path): \(reason)"
        case .quarantine: return "не удалось переместить повреждённый файл \(path): \(reason)"
        case .backup: return "не удалось сохранить резервную копию старых настроек в \(path): \(reason)"
        }
    }
    var configContentInvalid: String { "содержимое файла не является корректными настройками" }

    // 页名称：侧栏窄，用单个词。
    var pageClients: String { "Клиенты" }
    var pagePreviews: String { "Миниатюры" }
    var pageSwitching: String { "Переключение" }
    var pageAlerts: String { "Оповещения" }
    var pageProfiles: String { "Профили" }
    var pageGeneral: String { "Общие" }
    var pagePermissions: String { "Разрешения" }
    var pageAbout: String { "О программе" }

    // 客户端页。
    var clientsSubtitle: String { "Запущенные клиенты и персонажи, известные этому профилю." }
    var hideAllThumbnails: String { "Скрыть все миниатюры" }
    var hideAllHotkeyLabel: String { "Сочетание клавиш" }
    var hideAllScopeLabel: String { "Действует" }
    var hideAllHotkeyFooter: String {
        "Используйте модификаторы с клавишей (например, ⌃⌥⌘H) или со средней либо боковой кнопкой мыши. Все сочетания выше действуют в одной области, выбранной здесь."
    }
    var charactersHeader: String { "Персонажи" }
    var charactersFooter: String { "Этим цветом рисуется рамка подсветки, когда персонаж активен." }
    var noCharacters: String { "Персонажей пока нет. Запустите EVE и войдите персонажем." }
    var loginClientsHeader: String { "Клиенты на экране входа" }
    var showThumbnail: String { "Показывать миниатюру" }
    var highlightColorHelp: String { "Цвет подсветки, когда персонаж активен" }

    // 预览与布局页。
    var previewsSubtitle: String { "Размер, внешний вид и поведение миниатюр. Изменения применяются сразу." }
    var defaultSize: String { "Размер по умолчанию" }
    var minimumSize: String { "Минимальный размер" }
    var maximumSize: String { "Максимальный размер" }
    var unifySizes: String { "Вернуть всем миниатюрам размер по умолчанию" }
    var appearanceHeader: String { "Внешний вид" }
    var opacity: String { "Непрозрачность" }
    var showTitle: String { "Показывать имя персонажа" }
    var titleFontSize: String { "Размер шрифта имени" }
    var titleColor: String { "Цвет имени" }
    var borderEnabled: String { "Показывать рамку" }
    var borderColor: String { "Цвет рамки" }
    var borderThickness: String { "Толщина рамки" }
    var highlightEnabled: String { "Подсвечивать активный клиент" }
    var highlightColor: String { "Цвет подсветки" }
    var highlightThickness: String { "Толщина подсветки" }
    var zoomHeader: String { "Увеличение при наведении" }
    var zoomEnabled: String { "Увеличивать при наведении" }
    var zoomFactor: String { "Кратность увеличения" }
    var zoomAnchor: String { "Точка привязки" }
    var behaviorHeader: String { "Поведение" }
    var alwaysOnTop: String { "Миниатюры поверх других окон" }
    var hideActiveClient: String { "Скрывать миниатюру активного клиента" }
    var hideWhenNotEVE: String { "Скрывать миниатюры, когда EVE не на переднем плане" }
    var hideDelay: String { "Задержка скрытия" }
    var layoutHeader: String { "Расположение" }
    var snapEnabled: String { "Прилипание при перетаскивании" }
    var lockAspectRatio: String { "Сохранять пропорции при изменении размера" }
    var lockLayout: String { "Закрепить расположение" }
    var gestureHint: String {
        "Перетаскивайте правой кнопкой или с Option, чтобы переместить; тяните за край, чтобы изменить размер; "
            + "удерживайте Shift, чтобы отключить прилипание."
    }
    var captureHeader: String { "Захват и положение" }
    var frameRate: String { "Частота кадров" }
    var titleBarCrop: String { "Обрезка заголовка окна" }
    var pollInterval: String { "Интервал опроса окон" }
    var loginPositionX: String { "Миниатюра входа: X" }
    var loginPositionY: String { "Миниатюра входа: Y" }
    func anchorName(_ anchor: ZoomAnchor) -> String {
        switch anchor {
        case .nw: return "Вверху слева"
        case .n: return "Вверху"
        case .ne: return "Вверху справа"
        case .w: return "Слева"
        case .center: return "В центре"
        case .e: return "Справа"
        case .sw: return "Внизу слева"
        case .s: return "Внизу"
        case .se: return "Внизу справа"
        }
    }

    // 配置方案页。
    var profilesSubtitle: String { "Каждый профиль — полный набор настроек, расположений и групп переключения." }
    var activeBadge: String { "Текущий" }
    var switchTo: String { "Выбрать" }
    var rename: String { "Переименовать" }
    var clone: String { "Дублировать" }
    var newProfile: String { "Новый профиль" }
    var configFile: String { "Файл конфигурации" }
    var revealConfig: String { "Показать в Finder" }
    var profileName: String { "Имя профиля" }
    var profileNameRule: String { "От 1 до 64 символов, без повторов среди профилей (регистр не учитывается)." }
    func deleteProfileConfirm(_ name: String) -> String { "Удалить профиль «\(name)»? Это действие нельзя отменить." }
    func cloneTitle(_ name: String) -> String { "Дублировать «\(name)»" }
    func renameTitle(_ name: String) -> String { "Переименовать «\(name)»" }
    func copyName(_ name: String) -> String { "\(name) (копия)" }

    // 通用页。
    var generalSubtitle: String { "Настройки, общие для всех профилей." }
    var interfaceLanguage: String { "Язык интерфейса" }
    var followSystem: String { "Как в системе" }
    var machineTranslationNote: String { "Часть переводов выполнена машинным переводом. Будем рады исправлениям." }
    var showDockIcon: String { "Показывать значок в Dock" }
    var showDockIconHelp: String { "Если выключено, EVE-O Preview показывает только значок в строке меню." }

    // 权限页。
    var permissionsSubtitle: String {
        "Оба разрешения выдаются в разделе «Системные настройки» > «Конфиденциальность и безопасность»."
    }
    var screenRecording: String { "Запись экрана" }
    var screenRecordingDetail: String {
        "Нужно для захвата окон клиентов и чтения их заголовков. Обычно начинает действовать после перезапуска."
    }
    var accessibility: String { "Универсальный доступ" }
    var accessibilityDetail: String {
        "Нужно, чтобы разворачивать, выводить на передний план и сворачивать окна клиентов, "
            + "а также для горячих клавиш на кнопках мыши. Действует сразу."
    }
    var granted: String { "Разрешено" }
    var notGranted: String { "Не разрешено" }
    var request: String { "Запросить" }
    var openSystemSettings: String { "Открыть Системные настройки" }
    var relaunchHint: String { "Перезапустите после выдачи разрешения «Запись экрана»" }
    var relaunch: String { "Перезапустить" }
    var signingHint: String {
        "macOS привязывает разрешения к подписи кода. Для сборок с ad-hoc-подписью разрешения нужно выдавать "
            + "заново после каждой пересборки; в README описано, как использовать самоподписанный сертификат."
    }

    // 关于页。
    var version: String { "Версия" }
    var devVersion: String { "Сборка для разработки" }
    var aboutSubtitle: String {
        "Живые миниатюры и быстрое переключение между клиентами EVE Online, нативно для macOS."
    }
    var aboutSummary: String {
        "Живая миниатюра для каждого клиента, переключение щелчком, горячие клавиши групп переключения "
            + "и несколько профилей."
    }
    var upstreamHeader: String { "Исходный проект и лицензия" }
    var upstreamText: String { "Это приложение заново реализует возможности EveOPlus/eve-o-preview для macOS." }
    var licenseText: String {
        "Как и исходный проект, оно распространяется по лицензии GNU General Public License v3.0."
    }
    var disclaimerHeader: String { "Примечания" }
    var focusOnlyText: String {
        "Инструмент только переключает фокус окон. Он никогда не передает ввод сразу в несколько клиентов "
            + "и не читает и не изменяет память игры."
    }
    var gameLogText: String {
        "Боевые оповещения только читают файлы игрового журнала, которые пишет клиент EVE. "
            + "Они не читают память игры, не изменяют файлы и не отправляют ввод."
    }
    var networkText: String {
        "EVE-O Preview обращается к GitHub только для проверки и загрузки обновлений; это можно отключить "
            + "в разделе «Общие». Отчёты о проблемах никогда не отправляются автоматически."
    }
    var eveIPText: String {
        "EVE Online и связанные с ней логотипы являются товарными знаками CCP ehf. "
            + "Этот проект не связан с CCP и не одобрен ею."
    }
}

// MARK: - 预警与翻译（docs/design-intel-translate.md 第 11 节）
// 机器生成、待母语者审校的译文，用词按 11 节的词表：浮窗、预警、频道、聊天日志、模型服务。

/// 菜单栏的两个浮窗开关，俄文。
extension MenuStringsRU {
    var showIntelOverlay: String { "Показать оверлей разведки" }
    var showTranslationOverlay: String { "Показать оверлей перевода" }
}

/// 两个新页的页名、关于页的说明与聊天日志的状态，俄文。
extension SettingsStringsRU {
    var pageIntel: String { "Разведка" }
    var pageTranslation: String { "Перевод" }
    var aboutChatLogsNote: String {
        "Разведка и перевод только читают журналы чата и игровые журналы. Перевод отправляет текст чата выбранному вами сервису модели. Если включена онлайн-проверка имён, имена пилотов, идущие подряд в сообщениях разведки, отправляются в ESI API компании CCP."
    }
    var chatLogStatusStopped: String { "Выключено" }
    func chatLogStatusWatching(directory: String, files: Int) -> String {
        "Отслеживается \(files) \(russianPlural(files, one: "журнал", few: "журнала", many: "журналов")) в \(directory)"
    }
    func chatLogStatusDirectoryNotFound(_ path: String) -> String { "Папка журналов чата не найдена: \(path)" }
    func chatLogStatusAccessDenied(_ path: String) -> String { "Нет доступа к \(path)" }
    var chatLogHelp: String {
        "В клиенте EVE должна быть включена запись чата в файл. Папка журналов задаётся на странице «Оповещения»."
    }
}
