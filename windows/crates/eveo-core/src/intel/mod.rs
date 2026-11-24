// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警，对应 macOS 的 EVEOPreviewCore/Intel（docs/macos/design-intel-translate.md 6.4～6.8 节）。
// 这里是预警消息的解析结果：一条消息分成星系、舰船、人数、情报用语、推断的人名与普通文字几段，
// 并汇总出星系、舰船数量、人名与敌对数量。
// - parser：分段、人数与人名的规则（6.4 节）。
// - feed：按收听者分开的消息缓冲（每人至多 300 条，编号递增）。
// - counting：数量的归属、敌对数量与「安全」是否被否定（6.4 节「舰船的数量与敌对数量」）。
// - pilots：人名核对（ESI 请求写法、缓存、排队节流、按查到的角色重新分人，6.9～6.10 节）。
// - presenter：预警浮窗每一行的内容（6.7 节）：时间、星系与跳数、数量、舰船、人名、用语与强调背景。
// 消息本身由聊天日志的跟踪服务给出；星系与舰船靠 static_data 的术语匹配认出。

//! 预警消息的解析：分段、人数、人名与敌对数量。

mod counting;
pub mod feed;
pub mod parser;
pub mod pilots;
pub mod presenter;

#[cfg(test)]
mod tests;

use crate::static_data::matcher::{IntelWord, TermKind};

/// 一段文字的种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum IntelSegmentKind {
    /// 星系，关联值是星系 ID。
    System(i64),
    /// 星域，关联值是星域 ID。
    Region(i64),
    /// 舰船，关联值是舰船类型 ID。
    Ship(i64),
    /// 舰船分组，关联值是分组 ID。
    ShipGroup(i64),
    /// 情报用语。
    Word(IntelWord),
    /// 人数，关联值是数值。
    Count(i64),
    /// 推断的人名。
    Pilot,
    /// 普通文字与空白。
    Plain,
}

impl IntelSegmentKind {
    /// 是舰船或舰船分组。
    pub fn is_ship(self) -> bool {
        matches!(self, IntelSegmentKind::Ship(_) | IntelSegmentKind::ShipGroup(_))
    }

    /// 是星系、舰船或舰船分组（推断人名的前提）。
    pub fn is_system_or_ship(self) -> bool {
        matches!(self, IntelSegmentKind::System(_)) || self.is_ship()
    }
}

/// 原文里的一段。各段依次拼起来就是原文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IntelSegment {
    /// 原文里的这一段。
    pub text: String,
    /// 种类。
    pub kind: IntelSegmentKind,
}

impl IntelSegment {
    /// 用文字与种类建一段。
    pub fn new(text: &str, kind: IntelSegmentKind) -> Self {
        Self {
            text: text.to_owned(),
            kind,
        }
    }
}

/// 消息里提到的一艘舰船或一个舰船分组。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IntelShipMention {
    /// `TermKind::Ship` 或 `TermKind::ShipGroup`。
    pub kind: TermKind,
    /// 归给它的数量；没写数量时是 1。
    pub count: i64,
}

/// 一条消息的解析结果。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IntelReport {
    /// 分好的各段。
    pub segments: Vec<IntelSegment>,
    /// 星系 ID，去重，按出现顺序。
    pub system_ids: Vec<i64>,
    /// 舰船与数量。
    pub ships: Vec<IntelShipMention>,
    /// 推断的人名。
    pub pilots: Vec<String>,
    /// 敌对数量；`None` 表示判断不出。
    pub hostile_count: Option<i64>,
    /// 数量来自消息里写明的数字。
    pub count_is_explicit: bool,
    /// 消息里有「安全」一类的用语（没有被否定、不是疑问）。
    pub is_clear: bool,
    /// 消息里有「未见」一类的用语。
    pub is_no_visual: bool,
}

impl IntelReport {
    /// 认出了星系或舰船（含舰船分组），可以当作一条情报。
    pub fn is_intel_like(&self) -> bool {
        !self.system_ids.is_empty() || !self.ships.is_empty()
    }

    /// 什么也没认出的结果：全文是一段 Plain（空文字时没有段）。
    pub fn plain(text: &str) -> Self {
        let segments = if text.is_empty() {
            Vec::new()
        } else {
            vec![IntelSegment::new(text, IntelSegmentKind::Plain)]
        };
        Self {
            segments,
            ..Self::default()
        }
    }
}
