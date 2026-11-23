// SPDX-License-Identifier: GPL-3.0-or-later
//
// 缩略图规划，对应 macOS 的 Planning/ 与 Model/RuntimeModels.swift 里的会话状态（架构文档 3.3 节）。
// 规划器是纯函数：协调器收集状态成 PlannerInput，得到 ThumbnailPlan 后分发给缩略图窗口与配置。
//
// 与 macOS 的差别来自画面的来源：macOS 用 ScreenCaptureKit 捕获，要屏幕录制权限、要算捕获规格、
// 要裁掉标题栏；Windows 用 DWM 缩略图（DwmRegisterThumbnail），不要权限，系统直接合成，
// 只取客户区（fSourceClientAreaOnly），不用裁剪。所以这里没有权限、捕获状态、捕获规格与画面范围，
// 换成每个窗口的 DWM 缩略图状态。布局、可见性、外观的规则与 macOS 相同，由 shared/fixtures/planner 对齐。

//! 缩略图的可见性与呈现规划。

mod model;
pub mod planner;
pub mod visibility;

pub use model::{
    CombatAlertWindow, FrontmostContext, PlannerInput, SessionState, ThumbnailAlert, ThumbnailPlaceholder,
    ThumbnailPlan, ThumbnailPresentation, ThumbnailStatus,
};
pub use planner::plan;
