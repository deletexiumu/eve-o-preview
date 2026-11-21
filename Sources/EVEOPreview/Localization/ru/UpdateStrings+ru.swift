// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新域的俄文文字。译文由机器生成，待母语者审校（反馈文档 5.2 节）。
// 成员顺序与协议一致，每条的用途见 UpdateStrings.swift。
// 用词按 v1.1 设计 11.3 节的词表：обновление、Проверить наличие обновлений…（macOS 俄文版的说法）、
// примечания к выпуску、Установить обновление、Пропустить эту версию、Позже、подпись；
// 缩略图 миниатюра（反馈文档 5.5 节）。「重新启动」与现有的权限页一致写 Перезапустить；
// 「应用程序」文件夹写 «Программы»（macOS 俄文版的名称），引号用 «»。
// 本域的文字不带数量，不用处理复数。

import Foundation

/// 更新域的俄文实现。
struct UpdateStringsRU: UpdateStrings {
    // MARK: 菜单栏菜单

    var menuCheckForUpdates: String { "Проверить наличие обновлений…" }
    func menuUpdateAvailable(_ version: String) -> String { "Доступно обновление: \(version)…" }
    func menuRestartToUpdate(_ version: String) -> String { "Перезапустить и обновить до \(version)" }

    // MARK: 「通用」页的更新一组

    var sectionHeader: String { "Обновления" }
    var autoCheckToggle: String { "Автоматически проверять наличие обновлений" }
    var autoCheckHelp: String { "Обращается к GitHub раз в день. Личные данные не передаются." }
    var autoInstallToggle: String { "Автоматически устанавливать обновления" }
    var autoInstallHelp: String { "Загружает обновление в фоне. Устанавливает и перезапускает приложение, если клиент EVE не запущен в течение минуты, а также устанавливает при выходе из EVE-O Preview." }
    var currentVersionLabel: String { "Текущая версия" }
    var lastCheckedLabel: String { "Последняя проверка" }
    var lastCheckedNever: String { "Никогда" }
    var checkNowButton: String { "Проверить сейчас" }

    // MARK: 状态行

    var statusChecking: String { "Проверка…" }
    var statusUpToDate: String { "У вас последняя версия EVE-O Preview." }
    func statusAvailable(_ version: String) -> String { "Доступна версия \(version)." }
    func statusReady(_ version: String) -> String { "Версия \(version) загружена и будет установлена при выходе." }
    func statusRateLimited(_ time: String) -> String { "GitHub ограничивает запросы. Повторите попытку после \(time)." }
    var statusRateLimitedLater: String { "GitHub ограничивает запросы. Повторите попытку позже." }
    var statusUnavailable: String { "В этой сборке обновления недоступны." }

    // MARK: 更新窗口

    var windowTitle: String { "Обновление программы" }
    func headline(_ version: String) -> String { "Доступна EVE-O Preview \(version)" }
    func currentVersionLine(_ version: String) -> String { "У вас версия \(version)." }
    var releaseNotesHeader: String { "Что нового" }
    var installButton: String { "Установить обновление" }
    var installHelp: String {
        "После установки приложение перезапустится. Миниатюры пропадут на несколько секунд."
    }
    var skipButton: String { "Пропустить эту версию" }
    var laterButton: String { "Позже" }
    var openReleasePageButton: String { "Открыть страницу выпуска" }
    var cancelButton: String { "Отменить" }
    var closeButton: String { "Закрыть" }
    var retryButton: String { "Повторить" }
    func progressDownloading(received: String, total: String?) -> String {
        total.map { "Загрузка… \(received) из \($0)" } ?? "Загрузка… \(received)"
    }
    var progressVerifying: String { "Проверка файла…" }
    var progressInstalling: String { "Установка…" }
    var progressRelaunching: String { "Перезапуск…" }
    var testFeedBadge: String { "Тестовый адрес" }
    var notifyOnlyIntro: String { "Эта копия не может обновиться сама." }
    var currentVersionUnchanged: String { "Текущая версия не изменилась." }
    var reopenManually: String { "Обновление установлено. Завершите EVE-O Preview и откройте снова." }

    // MARK: 不能自动安装的原因

    var blockerTranslocated: String {
        "macOS запускает приложение из временного места только для чтения. "
            + "Переместите его в папку «Программы» и откройте снова."
    }
    var blockerReadOnlyVolume: String {
        "Приложение находится на диске только для чтения. Сначала скопируйте его в папку «Программы»."
    }
    var blockerLocationNotWritable: String { "У вас нет прав на изменение папки, в которой находится приложение." }
    var blockerAdHocSignature: String {
        "У этой сборки нет постоянной подписи, поэтому новую версию невозможно проверить."
    }
    var blockerDevelopmentSignature: String { "Это сборка для разработки с локальной подписью." }
    var blockerUnsigned: String { "Эта сборка не подписана." }

    // MARK: 错误

    var errorNetwork: String { "Не удалось подключиться к GitHub. Проверьте подключение к интернету." }
    func errorHTTPStatus(_ code: Int) -> String { "GitHub вернул ошибку (\(code))." }
    var errorMalformedFeed: String { "Не удалось прочитать сведения о выпуске." }
    var errorAssetMissing: String { "В этом выпуске нет установщика для автоматического обновления." }
    var errorDiskSpace: String { "Недостаточно свободного места на диске для загрузки." }
    var errorChecksum: String { "Загруженный файл не совпадает с контрольной суммой и удалён." }
    var errorDiskImage: String { "Не удалось открыть загруженный образ диска." }
    var errorVerification: String { "Не удалось проверить новую версию, поэтому она не установлена." }
    func errorUnsupportedSystem(_ minimum: String) -> String { "Для этой версии требуется macOS \(minimum) или новее." }
    var errorSwapFailed: String { "Не удалось заменить приложение." }
}
