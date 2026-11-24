// SPDX-License-Identifier: GPL-3.0-or-later
//
// 聊天翻译，对应 macOS 的 EVEOPreviewCore/Translation（docs/macos/design-intel-translate.md 第 7 节）。
// 这里是翻译用到的模型：接口种类与解析后的接口、失败的分类、消息的阶段、HTTP 请求与答复、缓存条目、队列的状态。
// 规则分在几个子模块里，都是纯函数：
// - providers：服务预设的接口种类、设置与预设的合并、明文 HTTP 只允许本机与局域网（7.3 节）。
// - rules：是否已是目标语言、不用模型的原因、缓存键、分批、模型结果换成阶段、术语替换（7.6 节、7.8 节）。
// - prompt：系统提示与用户消息（7.9 节）。
// - wire：拼出 HTTP 请求、按状态码归类失败、从答复里取出译文（7.4 节、7.5 节）。
// - cache：译文缓存（最近用过的留下）与缓存文件的格式（7.8 节）。
// - queue：按收听者分开的缓冲、分批发送、失败后的等待与重试（7.6 节）。
// - presenter：翻译浮窗的一行（7.10 节）。
// HTTP 的收发、API Key 的保存（Windows 凭据管理器）与定时调度在应用层，这里只有数据与纯规则。

//! 聊天翻译的模型与规则：预设、判断、分批、提示词、请求与答复。

pub mod cache;
pub mod presenter;
pub mod prompt;
pub mod providers;
pub mod queue;
pub mod rules;
pub mod wire;

#[cfg(test)]
mod tests;

use std::collections::BTreeMap;

use crate::chat_log::ChatMessage;
use crate::model::TranslationProviderId;

/// 模型服务的接口种类。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ApiKind {
    /// OpenAI 兼容的 `/chat/completions`。
    OpenAiCompatible,
    /// Anthropic 的 Messages API。
    Anthropic,
}

/// 解析好的接口：设置与预设合并后的结果（[`providers::resolve`]）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    /// 预设编号。
    pub provider: TranslationProviderId,
    /// 接口种类，随预设，改了地址也不变。
    pub kind: ApiKind,
    /// 接口地址，末尾没有 `/`。
    pub base_url: String,
    /// 地址的路径部分（不含查询串与片段，已去掉末尾的 `/`），空串表示没有路径。
    /// Anthropic 接口靠它判断要不要补 `/v1`。
    pub path: String,
    /// 模型名。
    pub model: String,
    /// 是否要 API Key。
    pub requires_key: bool,
}

/// 接口设置不能用的原因（7.3 节）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointIssue {
    /// 没有地址（设置与预设都为空）。
    MissingBaseUrl,
    /// 没有模型名。
    MissingModel,
    /// 解不开，或带用户名、查询串、片段，或协议不是 http、https。
    InvalidUrl,
    /// http 只允许本机与局域网地址。
    InsecureRemoteHttp,
}

/// 一次翻译失败的原因（7.5 节）。
#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    /// 接口设置不能用。
    NotConfigured(EndpointIssue),
    /// 预设要 Key，但没有 Key。
    MissingKey,
    /// 读凭据管理器失败（macOS 上是钥匙串要用户确认或被拒绝）。
    KeychainUnavailable,
    /// 401、403：Key 无效或没有权限。
    Unauthorized(u16),
    /// 404：地址或模型名不对。
    NotFound,
    /// 402：余额不足。
    InsufficientBalance,
    /// 3xx 与其他 4xx：请求不被接受。说明只显示在界面上，不写进日志。
    Rejected {
        /// HTTP 状态码。
        status: u16,
        /// 答复里的说明，至多 200 个字符。
        message: String,
    },
    /// 429：限流。答复给的等待秒数；没给或解析不了时为 None，由队列按连续次数加倍等待。
    RateLimited(Option<f64>),
    /// 408、409、5xx：服务出错。
    Server(u16),
    /// 连不上、超时、答复过大。
    Network(String),
    /// 答复不是要求的格式。
    MalformedAnswer,
    /// 模型拒绝了这批消息。
    Refused,
    /// 答复被截断。
    Truncated,
}

impl Failure {
    /// 设置有问题：改设置或手动重试前不再请求（7.5 节表里「是否致命」一栏）。
    pub fn is_fatal(&self) -> bool {
        matches!(
            self,
            Self::NotConfigured(_)
                | Self::MissingKey
                | Self::KeychainUnavailable
                | Self::Unauthorized(_)
                | Self::NotFound
                | Self::InsufficientBalance
                | Self::Rejected { .. }
        )
    }

    /// 非致命错误下次请求前至少等多久（秒）。
    ///
    /// 限流取答复给的秒数，没给时取 30 秒；服务出错与网络失败取 30 秒（连续失败时的加倍由队列负责）；
    /// 只影响这一批的失败（格式不对、被拒绝、被截断）与致命的失败是 0。
    pub fn retry_delay(&self) -> f64 {
        match self {
            Self::RateLimited(seconds) => seconds.unwrap_or(30.0),
            Self::Server(_) | Self::Network(_) => 30.0,
            _ => 0.0,
        }
    }
}

/// 消息不用交给模型的原因（7.6 节）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SkipReason {
    /// 说话人是 EVE 系统。
    SystemSpeaker,
    /// 正文为空。
    Empty,
    /// 已经是目标语言。
    SameLanguage,
    /// 只有星系、舰船与情报用语，按术语替换即可。
    TermsOnly,
}

/// 一条消息在翻译流程里的阶段。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    /// 不用模型。第二项是只做术语替换后的文字，与原文相同时为 None。
    Skipped(SkipReason, Option<String>),
    /// 不排队（补读的旧消息、非活动角色的消息）。
    Off,
    /// 排队等待发送。
    Pending,
    /// 在途的一批里。
    InFlight,
    /// 已翻译。
    Done {
        /// 译文。
        text: String,
        /// 模型判断的原文语言代码。
        source_language: Option<String>,
    },
    /// 这一条翻译失败，不再自动重试（用户点重试时重新排队）。
    Failed,
}

/// 翻译缓冲里的一条消息。
#[derive(Debug, Clone, PartialEq)]
pub struct TranslationItem {
    /// 在整个缓冲里递增的编号。
    pub id: u64,
    /// 原消息。
    pub message: ChatMessage,
    /// 当前阶段。
    pub phase: Phase,
}

/// 一条译文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranslatedText {
    /// 译文。
    pub text: String,
    /// 模型判断的原文语言代码（小写，至多 8 个字符）；模型没给时为 None。
    pub source_language: Option<String>,
}

/// 交给传输层的 HTTP 请求，方法总是 POST。
#[derive(Debug, Clone, PartialEq)]
pub struct HttpRequest {
    /// 完整的地址。
    pub url: String,
    /// 请求头，按名字排序。含 Key 的请求头不应写进任何日志。
    pub headers: BTreeMap<String, String>,
    /// JSON 请求体。
    pub body: Vec<u8>,
    /// 超时，单位是秒。
    pub timeout_seconds: f64,
}

/// 传输层交回的答复。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    /// HTTP 状态码。
    pub status: u16,
    /// 答复头，键是小写。
    pub headers: BTreeMap<String, String>,
    /// 答复正文。
    pub body: Vec<u8>,
}

/// 传输层的失败。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    /// 连不上、超时或其他发送失败，关联值是系统给的说明。
    Network(String),
    /// 答复正文超过 1 MiB。
    TooLarge,
}

/// 翻译队列的状态（7.6 节），显示在翻译浮窗与「翻译」页的状态行。
#[derive(Debug, Clone, PartialEq)]
pub enum TranslationStatus {
    /// 功能没开。
    Off,
    /// 没有在途的请求。
    Idle,
    /// 有一批在途。
    Translating,
    /// 限流或临时故障，到 until（墙上时钟的秒数）时自动重试。
    Waiting {
        /// 自动重试的时刻。
        until: f64,
        /// 原因。
        reason: Failure,
    },
    /// 设置有问题，等用户处理。
    Blocked(Failure),
}
