// SPDX-License-Identifier: GPL-3.0-or-later
//
// 人名核对，对应 macOS 的 PilotLookupModels.swift 及同目录的几个文件（docs/macos/design-intel-translate.md
// 6.9 节、6.10 节）。解析器推断出的人名只是「像人名的词」，联网向 ESI 核对后才知道哪些真有这个角色，
// 再据此把一串词重新分成几个人。
// - 本文件：值类型。
//   - PilotLookupOutcome：一个名字在 ESI 的结果：查到角色、与游戏对象重名、没查到。
//   - PilotLookupAnswer：一次请求的结果，按比较键 key 存各名字的结果，另带 ESI 的错误额度。
//   - PilotLookupFailure：一次请求失败的原因，决定排队时等多久、要不要重发。
//   - PilotNameCacheEntry：人名缓存文件里的一项，只存查到的角色。
//   - PilotLookupStatus：核对的状态，给「预警」页与问题报告。
// - wire：ESI 请求的写法与答复的解析（只拼请求、解析答复，不发请求）。
// - cache：结果的缓存（查到的 30 天并存盘，其余 6 小时只在内存）。
// - queue：排队与节流的状态机（不读时钟，时刻由调用方传入）。
// - segmenter：按核对结果给人名段分人，并重算敌对数量。
// 名字是消息正文的一部分，这些类型都不写进日志；发请求与读写缓存文件在 app 层。

//! 人名核对：值类型、ESI 写法、缓存、排队与分人。

pub mod cache;
pub mod queue;
pub mod segmenter;
pub mod wire;

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// 一个名字在 ESI 的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PilotLookupOutcome {
    /// ESI 有同名的角色；name 是 ESI 返回的写法（大小写以 ESI 为准）。
    Matched {
        /// 角色 ID。
        character_id: i64,
        /// ESI 返回的写法。
        name: String,
    },
    /// 有同名的角色，但同名的还有物品、星系等游戏对象，消息里指的多半是后者。
    Ambiguous,
    /// 没有同名的角色。
    NotFound,
}

impl PilotLookupOutcome {
    /// 查到角色的简写构造。
    pub fn matched(character_id: i64, name: &str) -> Self {
        Self::Matched {
            character_id,
            name: name.to_owned(),
        }
    }
}

/// 一次请求的结果。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PilotLookupAnswer {
    /// 各名字的结果。键是 [`key`] 的结果；请求里的每个名字各有一项。
    pub outcomes: HashMap<String, PilotLookupOutcome>,
    /// 答复头 `X-Esi-Error-Limit-Remain`：本时段还能出错的次数。没有这个头时为 None。
    pub error_limit_remain: Option<i64>,
    /// 答复头 `X-Esi-Error-Limit-Reset`：错误额度多少秒后重置。没有这个头时为 None。
    pub error_limit_reset: Option<i64>,
}

impl PilotLookupAnswer {
    /// 只有结果、没有错误额度的答复。
    pub fn new(outcomes: HashMap<String, PilotLookupOutcome>) -> Self {
        Self {
            outcomes,
            ..Self::default()
        }
    }
}

/// 名字的比较键：去掉首尾空白，连续的空白（含制表符与换行）并成一个空格，转成小写。
/// ESI 按整个名字匹配、不区分大小写，缓存、去重与答复的对照都用这个键。
pub fn key(name: &str) -> String {
    normalize(name).to_lowercase()
}

/// 连续的空白并成一个空格并去掉首尾空白，不改大小写（发给 ESI 的写法）。
pub(crate) fn normalize(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// 一次请求失败的原因。失败的请求不产生任何结果，缓存不变。
#[derive(Debug, Clone, PartialEq)]
pub enum PilotLookupFailure {
    /// 连不上、超时、答复过大。关联值是给日志的简短说明，不含名字。
    Network(String),
    /// 420、429：ESI 要求等这么多秒再发。
    RateLimited {
        /// 等待的秒数，已夹到 5～600。
        retry_after: f64,
    },
    /// 408、5xx：服务端的问题，稍后重发。
    Server {
        /// HTTP 状态码。
        status: u16,
    },
    /// 3xx 与其他 4xx：请求本身有问题，不重发。
    Rejected {
        /// HTTP 状态码。
        status: u16,
    },
    /// 200，但正文不是预期的 JSON。
    MalformedAnswer,
}

/// 人名缓存文件里的一项（`pilot-names.json` 的 `entries`）。JSON 的键与 macOS 相同：key、characterID、name、time。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PilotNameCacheEntry {
    /// 比较键，[`key`] 的结果。
    pub key: String,
    /// 角色 ID。
    #[serde(rename = "characterID")]
    pub character_id: i64,
    /// ESI 返回的写法。
    pub name: String,
    /// 查到的时刻，UTC，1970 年以来的秒数。
    pub time: f64,
}

/// 人名核对的状态。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PilotLookupStatus {
    /// 预警或「联网核对人名」关着。
    Off,
    /// 没有在途的请求，也不在等待。
    Idle,
    /// 有一批名字在途。
    Resolving,
    /// 被限流或连续失败，等到这个时刻（墙上时钟，1970 年以来的秒数）再发。
    Waiting(f64),
}

impl PilotLookupStatus {
    /// 写进问题报告的代号：off、idle、resolving、waiting。不含等待的时刻（时刻对排查没有用，还会让报告每次都不同）。
    pub fn code(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Idle => "idle",
            Self::Resolving => "resolving",
            Self::Waiting(_) => "waiting",
        }
    }
}
