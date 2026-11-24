// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天功能（预警与翻译）的控制器，对应 macOS 的 Chat/ 目录（docs/macos/design-intel-translate.md 9.2 节）。
// - ChatFeedContext：交给功能控制器的上下文（配置方案、全局设置、星图数据、活动角色、聊天日志状态、界面语言）。
//   任何一项变了，应用层都再交一次；控制器与上一次比较，得出要做的事。
// - IntelFormatter：用 eveo-l10n 的预警文字实现 Core 的 IntelLineFormatting（时间、跳数、数量与用语）。
// - intel：预警功能的控制器（6.8 节）。
// - features：预警与翻译的总控（9.2 节）：算跟踪请求、分发日志事件、按时间刷新。
// - static_file：星图数据的来源（环境变量、用户覆盖文件、嵌进 exe 的数据）与读取（4.4 节）。
// 时钟：日志里的时间与「多久以前」用墙上时钟（1970 年以来的秒数），由调用方传入 now，测试里可以随意给。
// 这里不写日志：消息正文、说话人与人名都不该进诊断日志。

//! 预警与翻译的功能控制器。

use std::sync::Arc;

use eveo_core::chat_log::ChatLogStatus;
use eveo_core::intel::presenter::IntelLineFormatting;
use eveo_core::model::{AppLanguage, GeneralSettings, Profile};
use eveo_core::static_data::EveStaticData;
use eveo_core::static_data::jumps::JumpDistance;

pub mod features;
pub mod intel;
pub mod static_file;

#[cfg(test)]
mod features_tests;
#[cfg(test)]
mod tests;

/// 交给功能控制器的上下文。任何一项变了都会再交一次。
#[derive(Debug, Clone)]
pub struct ChatFeedContext {
    /// 当前配置方案（含 intel 与 translation 的设置）。
    pub profile: Profile,
    /// 全局设置（日志目录、模型服务的接口设置）。
    pub general: GeneralSettings,
    /// 星图数据；还没读完、缺失或无效时为 None。几个控制器共用同一份，用 Arc 免得复制。
    pub static_data: Option<Arc<EveStaticData>>,
    /// 活动角色；没有时为 None。
    pub active_character: Option<String>,
    /// 聊天日志跟踪服务的状态。
    pub chat_log_status: ChatLogStatus,
    /// 界面语言。
    pub language: AppLanguage,
}

/// 预警行的界面文字（对应 macOS 的 IntelLineFormatter）。按建它时的语言取文字；换语言后控制器下一次生成内容时新建一个。
#[derive(Debug, Clone, Copy)]
pub struct IntelFormatter {
    /// 界面语言。
    pub language: AppLanguage,
}

impl IntelLineFormatting for IntelFormatter {
    /// 多久以前：不足 60 秒写秒数，其余写分钟数（向下取整）。
    fn age(&self, seconds: i64) -> String {
        let text = eveo_l10n::intel(self.language);
        if seconds < 60 {
            text.age_seconds(seconds.max(0))
        } else {
            text.age_minutes(seconds / 60)
        }
    }

    /// 跳数：0 跳写「本星系」，超过上限、没有星门与出发点未知各有写法。
    fn jumps(&self, distance: JumpDistance) -> String {
        let text = eveo_l10n::intel(self.language);
        match distance {
            JumpDistance::Jumps(0) => text.jumps_here().to_owned(),
            JumpDistance::Jumps(count) => text.jumps(count),
            JumpDistance::Beyond(limit) => text.jumps_beyond(limit),
            JumpDistance::Unreachable => text.jumps_unreachable().to_owned(),
            JumpDistance::UnknownOrigin => text.jumps_unknown().to_owned(),
        }
    }

    /// 数量：写明的是「×N」，推断的是「约 ×N」。
    fn count(&self, value: i64, is_explicit: bool) -> String {
        let text = eveo_l10n::intel(self.language);
        if is_explicit {
            text.count(value)
        } else {
            text.count_inferred(value)
        }
    }

    /// 「安全」。
    fn clear(&self) -> String {
        eveo_l10n::intel(self.language).clear().to_owned()
    }

    /// 「未见」。
    fn no_visual(&self) -> String {
        eveo_l10n::intel(self.language).no_visual().to_owned()
    }
}

/// 秒数取整：负数与非有限值记 0，过大的值截到 10 亿秒（约 31 年），换成整数不会溢出。
pub fn whole_seconds(value: f64) -> i64 {
    if !value.is_finite() || value <= 0.0 {
        return 0;
    }
    value.min(1e9) as i64
}
