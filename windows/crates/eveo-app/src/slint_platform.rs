// SPDX-License-Identifier: GPL-3.0-or-later
//
// 应用的 Slint 平台：包一层 winit 后端，只改一件事——建窗口时，eveo-ui 的浮窗宿主事先放好了自己的
// 离屏软件渲染窗口，就用它（浮窗由 Win32 的分层窗口显示，见 eveo-ui 的 overlay::host 与平台层的 panel 模块）；
// 否则照常建 winit 的窗口（设置窗口）。事件循环、定时器、剪贴板等都原样转交给 winit 后端。
//
// 必须在第一次使用 Slint 之前装好：Slint 第一次需要平台时会自动选默认后端，之后就不能再换。
// 转交的方法里有两个带内部令牌（InternalToken），只能原样传下去，所以 i-slint-core 与 slint 的版本必须完全一致。

//! 包了一层 winit 后端的 Slint 平台。

use std::rc::Rc;
use std::time::Duration;

use i_slint_core::{InternalToken, SlintContextWeak};
use slint::PlatformError;
use slint::platform::{Clipboard, EventLoopProxy, Platform, WindowAdapter};

/// 包了一层 winit 后端的平台。
struct AppPlatform {
    /// winit 后端（软件渲染）。
    inner: i_slint_backend_winit::Backend,
}

impl Platform for AppPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError> {
        // 浮窗宿主放好的离屏窗口用一次即清空，不会被下一个窗口误用。
        if let Some(adapter) = eveo_ui::overlay::host::take_pending_adapter() {
            return Ok(adapter);
        }
        self.inner.create_window_adapter()
    }

    fn run_event_loop(&self) -> Result<(), PlatformError> {
        self.inner.run_event_loop()
    }

    fn process_events(
        &self,
        timeout: Option<Duration>,
        token: InternalToken,
    ) -> Result<core::ops::ControlFlow<()>, PlatformError> {
        self.inner.process_events(timeout, token)
    }

    fn bind_context(&self, context: SlintContextWeak, token: InternalToken) {
        // winit 后端靠它拿到 Slint 的上下文（定时器、窗口表），必须转交。
        self.inner.bind_context(context, token);
    }

    fn new_event_loop_proxy(&self) -> Option<Box<dyn EventLoopProxy>> {
        self.inner.new_event_loop_proxy()
    }

    fn duration_since_start(&self) -> Duration {
        self.inner.duration_since_start()
    }

    fn click_interval(&self) -> Duration {
        self.inner.click_interval()
    }

    fn cursor_flash_cycle(&self) -> Duration {
        self.inner.cursor_flash_cycle()
    }

    fn set_clipboard_text(&self, text: &str, clipboard: Clipboard) {
        self.inner.set_clipboard_text(text, clipboard);
    }

    fn clipboard_text(&self, clipboard: Clipboard) -> Option<String> {
        self.inner.clipboard_text(clipboard)
    }

    fn debug_log(&self, arguments: core::fmt::Arguments) {
        self.inner.debug_log(arguments);
    }

    fn open_url(&self, url: &str) -> Result<(), PlatformError> {
        self.inner.open_url(url)
    }
}

/// 装好应用的 Slint 平台。winit 后端建不起来（极少见，如显卡驱动异常）时返回错误，调用方照常运行，
/// Slint 之后会自己选默认后端，只是浮窗用不了离屏渲染。
pub fn install() -> Result<(), PlatformError> {
    let inner = i_slint_backend_winit::Backend::new()?;
    slint::platform::set_platform(Box::new(AppPlatform { inner }))
        .map_err(|e| PlatformError::Other(e.to_string()))
}
