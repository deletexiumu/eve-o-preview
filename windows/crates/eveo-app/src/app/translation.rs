// SPDX-License-Identifier: GPL-3.0-or-later
//
// 翻译功能的接线，对应 macOS 的 SettingsViewModel+Translation.swift 与 PlatformServices 里翻译用的两项：
// - 服务：API Key 用 Windows 凭据管理器（eveo_platform_win::credentials），请求用 WinHTTP
//   （eveo_platform_win::translation::send），译文缓存放在 %LOCALAPPDATA%\EVE-O Preview\cache。
//   控制器本身（排队、发送、缓存、Key 的读取时机）在 eveo-app-core::translation，接在聊天总控里。
// - 「翻译」页的按钮：保存 Key、删除 Key、立即重试、测试、清空缓存。都转成输入排队，在应用的循环里执行。
// - 「翻译」页的运行时状态：每次定时器都算一份 TranslationView，与上一次不同才交给界面
//   （状态行在等待时每秒变一次，Key、测试与缓存条数随操作变）。
// - 测试结果：控制器的结果在定时器里取走，换成「成功：译文」或「失败：原因」留给页面显示；换服务预设时清掉。
// 隐私：Key 只经过内存与凭据管理器，不写日志；控制器的日志行在诊断日志接上之前丢掉。

//! 「翻译」页与翻译服务的接线。

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use eveo_app_core::paths::DataPaths;
use eveo_app_core::translation::store::TranslationCacheStore;
use eveo_app_core::translation::text::{failure_text, issue_text, status_text};
use eveo_app_core::translation::{SecretError, SecretStore, TranslationController, TranslationServices};
use eveo_core::chat_log::ChatLogStatus;
use eveo_core::model::{AppLanguage, TranslationProviderId};
use eveo_core::overlay::OverlayKind;
use eveo_core::translation::{HttpRequest, TranslationStatus, providers};
use eveo_platform_win::credentials::{self, CredentialError};
use eveo_ui::translation::{TranslationView, clear_key_draft, show_translation_view};
use slint::ComponentHandle;

use super::intel::wall_clock;
use super::{App, Input, Runtime, post};

/// 「翻译」页的按钮。
#[derive(Debug, Clone)]
pub(super) enum TranslationAction {
    /// 「保存」：输入框里的 Key。
    SaveKey(String),
    /// 「删除 Key」。
    DeleteKey,
    /// 「立即重试」。
    Retry,
    /// 「测试」。
    Test,
    /// 「清空缓存」。
    ClearCache,
}

/// 「翻译」页在应用里的状态：控制器之外、只给页面显示的几项。
#[derive(Debug, Default)]
pub(super) struct TranslationPage {
    /// 保存或删除 Key 失败的说明；成功后清空。
    key_error: String,
    /// 测试结果的文字与是否成功；还没测过时为 None。
    test: Option<(String, bool)>,
    /// 上一次交给界面的状态，没变时不再交。填页面的方法只借用应用，所以放在 RefCell 里。
    shown: RefCell<Option<TranslationView>>,
}

/// 凭据管理器：把平台层的读写接到控制器的 SecretStore 上。
struct CredentialSecrets;

impl SecretStore for CredentialSecrets {
    fn read(&self, account: &str) -> Result<Option<String>, SecretError> {
        credentials::read(account).map_err(secret_error)
    }

    fn write(&self, account: &str, secret: &str) -> Result<(), SecretError> {
        credentials::write(account, secret).map_err(secret_error)
    }

    fn delete(&self, account: &str) -> Result<(), SecretError> {
        credentials::delete(account).map_err(secret_error)
    }
}

/// 平台层的凭据错误换成控制器的。
fn secret_error(error: CredentialError) -> SecretError {
    match error {
        CredentialError::TooLong => SecretError::TooLong,
        CredentialError::System(code) => SecretError::System(code),
    }
}

/// 建翻译控制器：凭据管理器、WinHTTP 与 cache 目录下的缓存文件。建好后就在后台读缓存文件。
pub(super) fn controller(paths: &DataPaths) -> TranslationController {
    // 版本号进 User-Agent（只有应用名与版本，没有用户的任何信息）。
    let version = env!("CARGO_PKG_VERSION");
    TranslationController::new(TranslationServices {
        secrets: Box::new(CredentialSecrets),
        transport: Arc::new(move |request: &HttpRequest| {
            eveo_platform_win::translation::send(request, version)
        }),
        cache_store: TranslationCacheStore::in_dir(&paths.cache_dir()),
    })
}

/// 接上「翻译」页的按钮：都转成输入排队，不在 Slint 的事件处理中途借用应用。
pub(super) fn connect(window: &eveo_ui::SettingsWindow, runtime: &Rc<Runtime>) {
    let model = window.global::<eveo_ui::TranslationModel>();
    // 不带参数的按钮用同一个闭包工厂。
    let send = |action: TranslationAction| {
        let weak = Rc::downgrade(runtime);
        move || post(&weak, Input::Translation(action.clone()))
    };
    // 「保存」带着输入框里的草稿，单独接；其余按钮不带参数。
    model.on_delete_key(send(TranslationAction::DeleteKey));
    model.on_retry(send(TranslationAction::Retry));
    model.on_test(send(TranslationAction::Test));
    model.on_clear_cache(send(TranslationAction::ClearCache));
    let weak = Rc::downgrade(runtime);
    model.on_save_key(move |key| {
        post(
            &weak,
            Input::Translation(TranslationAction::SaveKey(key.to_string())),
        );
    });
}

impl App {
    /// 执行「翻译」页的一个按钮，然后刷新页面与翻译浮窗。
    pub(super) fn translation_action(&mut self, action: TranslationAction) {
        let now = wall_clock();
        let config = self.coordinator.config();
        let endpoint = config.general.translation_endpoint.clone();
        // 测试用的目标语言与浮窗相同：「跟随界面」时取界面语言。
        let target = config
            .active_profile()
            .map(|p| p.translation.target_language.resolved(self.language))
            .unwrap_or(self.language);
        // 翻译控制器在启动时就接上；没有时（不会发生）按钮什么也不做。
        let Some(controller) = self.chat.features.translation_mut() else {
            return;
        };
        match action {
            TranslationAction::SaveKey(key) => {
                // 空白的输入不保存，也不清掉输入框。
                if key.trim().is_empty() {
                    return;
                }
                match controller.save_key(&key, endpoint.provider, now) {
                    Ok(()) => {
                        self.chat.translation_page.key_error.clear();
                        if let Some(window) = &self.settings {
                            clear_key_draft(window);
                        }
                    }
                    Err(error) => self.chat.translation_page.key_error = key_error_text(self.language, error),
                }
            }
            // 删除只影响当前预设的那一项凭据；之后浮窗会因缺 Key 暂停（要 Key 的预设）。
            TranslationAction::DeleteKey => match controller.delete_key(endpoint.provider, now) {
                Ok(()) => self.chat.translation_page.key_error.clear(),
                Err(error) => self.chat.translation_page.key_error = key_error_text(self.language, error),
            },
            // 重试清掉暂停与等待，失败的近期消息重新排队。
            TranslationAction::Retry => controller.retry(now),
            TranslationAction::Test => {
                self.chat.translation_page.test = None;
                controller.start_test(&endpoint, target, now);
            }
            // 清空后已翻译的句子再出现时会重新付费，所以按钮只在有缓存时可点。
            TranslationAction::ClearCache => controller.clear_cache(now),
        }
        // 测试在发请求之前就失败（地址不对、缺 Key）时结果已经有了，这里一并取走。
        self.take_translation_test();
        self.show_translation_page();
        self.refresh_overlay(OverlayKind::Translation);
    }

    /// 换了服务预设：Key 的输入框、失败说明与测试结果都属于旧预设，清掉。
    pub(super) fn translation_provider_changed(&mut self) {
        self.chat.translation_page.key_error.clear();
        self.chat.translation_page.test = None;
        if let Some(window) = &self.settings {
            clear_key_draft(window);
        }
    }

    /// 取走控制器里的测试结果，换成页面上的文字。
    pub(super) fn take_translation_test(&mut self) {
        let language = self.language;
        let Some(result) = self
            .chat
            .features
            .translation_mut()
            .and_then(|c| c.take_test_result())
        else {
            return;
        };
        // 成功显示译文，失败显示原因（与状态行的写法相同）。
        let text = eveo_l10n::translation(language);
        self.chat.translation_page.test = Some(match result {
            Ok(translated) => (text.test_succeeded(&translated), true),
            Err(failure) => (text.test_failed(&failure_text(language, &failure)), false),
        });
    }

    /// 设置窗口开着时算一份「翻译」页的运行时状态，与上一次不同才交给界面。
    pub(super) fn show_translation_page(&self) {
        let Some(window) = &self.settings else {
            return;
        };
        // 每次定时器都算一份；算起来很便宜（几次字符串格式化），交给界面才有成本。
        let view = self.translation_view();
        let mut shown = self.chat.translation_page.shown.borrow_mut();
        if shown.as_ref() == Some(&view) {
            return;
        }
        show_translation_view(window, &view);
        *shown = Some(view);
    }

    /// 不管上一次是什么，整组重填一次（打开窗口、换界面语言之后：缓存条数等文字随语言变）。
    pub(super) fn show_translation_page_again(&self) {
        self.chat.translation_page.shown.take();
        self.show_translation_page();
    }

    /// 「翻译」页的运行时状态。
    fn translation_view(&self) -> TranslationView {
        let language = self.language;
        let endpoint = &self.coordinator.config().general.translation_endpoint;
        let controller = self.chat.features.translation();
        // 状态行的文字含「几秒后重试」，用当前的墙上时钟算。
        let status = controller.map_or(TranslationStatus::Off, |c| c.status().clone());
        // 聊天日志的错误单独提示：翻译依赖它，但状态行只说翻译队列。
        let settings_text = eveo_l10n::settings(language);
        let chat_log_problem = match self.chat.features.chat_log_status() {
            ChatLogStatus::DirectoryNotFound(path) => settings_text.chat_log_status_directory_not_found(path),
            ChatLogStatus::AccessDenied(path) => settings_text.chat_log_status_access_denied(path),
            ChatLogStatus::Stopped | ChatLogStatus::Watching { .. } => String::new(),
        };
        // Key 的失败说明与测试结果只在应用里，控制器不记。
        let page = &self.chat.translation_page;
        let (test_result, test_succeeded) = page.test.clone().unwrap_or_default();
        TranslationView {
            status_text: status_text(language, &status, wall_clock()),
            needs_attention: matches!(
                status,
                TranslationStatus::Blocked(_) | TranslationStatus::Waiting { .. }
            ),
            chat_log_problem,
            endpoint_issue: providers::resolve(endpoint)
                .err()
                .map(|issue| issue_text(language, issue))
                .unwrap_or_default(),
            // 没读过 Key（功能还没打开过）时按没有显示，与 macOS 相同：不为了显示这一行去读凭据。
            key_stored: controller.and_then(|c| c.is_key_stored(endpoint.provider)) == Some(true),
            key_optional: endpoint.provider == TranslationProviderId::Custom,
            key_error: page.key_error.clone(),
            testing: controller.is_some_and(TranslationController::is_testing),
            test_result,
            test_succeeded,
            cache_count: controller.map_or(0, TranslationController::cache_count),
        }
    }
}

/// 凭据管理器失败的文字：附系统错误码（十进制的 HRESULT）；Key 过长时错误码记 -1。
fn key_error_text(language: AppLanguage, error: SecretError) -> String {
    let code = match error {
        SecretError::TooLong => -1,
        SecretError::System(code) => code,
    };
    eveo_l10n::translation(language).keychain_error(code)
}
