// SPDX-License-Identifier: GPL-3.0-or-later
//
// 弹出菜单（缩略图的右键菜单与托盘菜单）：CreatePopupMenu 建菜单，TrackPopupMenu 带 TPM_RETURNCMD
// 同步等用户选择，直接返回选中项的编号，不经过 WM_COMMAND。弹出前要把所有者窗口设为前台，
// 否则点菜单外面时菜单不消失（TrackPopupMenu 文档的「备注」一节）。菜单期间系统跑自己的模态消息循环，
// 调用方要能承受这期间别的消息被分发（应用层把事件排队，菜单返回后再处理）。

//! 弹出菜单。

use eveo_core::geometry::ScreenPoint;
use windows::Win32::Foundation::HWND;
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, DestroyMenu, HMENU, MENU_ITEM_FLAGS, MF_CHECKED, MF_GRAYED, MF_POPUP,
    MF_SEPARATOR, MF_STRING, PostMessageW, SetForegroundWindow, TPM_RETURNCMD, TPM_RIGHTBUTTON,
    TrackPopupMenu, WM_NULL,
};
use windows::core::{PCWSTR, Result};

use crate::text::wide;

/// 菜单里的一项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuEntry {
    /// 可点的一项。
    Item {
        /// 选中后返回的编号，不能是 0（0 表示没选）。
        id: u32,
        /// 显示的文字。
        text: String,
        /// 是否可点；不可点时置灰。
        enabled: bool,
        /// 是否打勾。
        checked: bool,
    },
    /// 子菜单。
    Submenu {
        /// 显示的文字。
        text: String,
        /// 子菜单里的项。
        entries: Vec<MenuEntry>,
    },
    /// 分隔线。
    Separator,
}

impl MenuEntry {
    /// 可点、不打勾的一项。
    pub fn item(id: u32, text: impl Into<String>) -> Self {
        Self::Item {
            id,
            text: text.into(),
            enabled: true,
            checked: false,
        }
    }
}

/// 在 `point` 处弹出菜单并等用户选择，返回选中项的编号；没选（点了外面或按 Esc）时返回 `None`。
/// `owner` 是本线程的一个窗口，菜单期间作为前台窗口。
pub fn popup(owner: HWND, point: ScreenPoint, entries: &[MenuEntry]) -> Result<Option<u32>> {
    let menu = build(entries)?;
    // SAFETY: owner 属于本线程；菜单由 build 建立，返回后销毁（连同子菜单）。
    let chosen = unsafe {
        let _ = SetForegroundWindow(owner);
        let chosen = TrackPopupMenu(
            menu,
            TPM_RETURNCMD | TPM_RIGHTBUTTON,
            point.x.round() as i32,
            point.y.round() as i32,
            None,
            owner,
            None,
        );
        // 文档要求：菜单关闭后给所有者发一条消息，否则下次弹出时可能立即消失。
        let _ = PostMessageW(Some(owner), WM_NULL, Default::default(), Default::default());
        let _ = DestroyMenu(menu);
        chosen.0
    };
    Ok(u32::try_from(chosen).ok().filter(|&id| id != 0))
}

/// 按项建一个弹出菜单（递归建子菜单）。
fn build(entries: &[MenuEntry]) -> Result<HMENU> {
    // SAFETY: 新建的菜单由调用方销毁。
    let menu = unsafe { CreatePopupMenu()? };
    for entry in entries {
        // 文字缓冲区要活到 AppendMenuW 返回；系统会复制文字。
        let result = match entry {
            MenuEntry::Item {
                id,
                text,
                enabled,
                checked,
            } => {
                let mut flags = MF_STRING;
                if !enabled {
                    flags |= MF_GRAYED;
                }
                if *checked {
                    flags |= MF_CHECKED;
                }
                let text = wide(text);
                // SAFETY: 菜单有效，文字缓冲区在调用期间有效。
                unsafe { AppendMenuW(menu, flags, *id as usize, PCWSTR(text.as_ptr())) }
            }
            MenuEntry::Submenu { text, entries } => {
                let sub = build(entries)?;
                let text = wide(text);
                // SAFETY: 子菜单的句柄作为编号传入，之后归父菜单所有，随父菜单一起销毁。
                unsafe { AppendMenuW(menu, MF_POPUP, sub.0 as usize, PCWSTR(text.as_ptr())) }
            }
            MenuEntry::Separator => {
                // SAFETY: 菜单有效；分隔线没有文字。
                unsafe { AppendMenuW(menu, MF_SEPARATOR | MENU_ITEM_FLAGS(0), 0, PCWSTR::null()) }
            }
        };
        if let Err(error) = result {
            // SAFETY: 出错时销毁已建的部分。
            let _ = unsafe { DestroyMenu(menu) };
            return Err(error);
        }
    }
    Ok(menu)
}
