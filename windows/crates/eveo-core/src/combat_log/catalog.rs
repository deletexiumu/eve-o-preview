// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的多语言短语表（反馈文档 7.5 节、7.6 节），与 macOS 的 CombatLogCatalog.swift 相同。
// 取自上游的 EveLogLanguageCatalog.cs（模板编号 285197～285204）与真实日志的格式。
// 日志的语言与界面语言无关：8 种语言的短语同时生效，不设语言选项。
// 匹配时一律不区分大小写；短语表只做前缀、后缀与子串比较，不用正则表达式（7.10 节）。

//! 游戏日志的多语言短语表。

/// 文件头里收听者一行的标签，后面紧跟半角或全角冒号。
///
/// 英文与中文有真实日志为证，俄文与日文有上游的录制样例，其余 4 种取自上游模板。
pub const LISTENER_LABELS: [&str; 8] = [
    "Listener",  // 英文
    "收听者",    // 中文
    "Слушатель", // 俄文
    "傍聴者",    // 日文
    "Empfänger", // 德文
    "Auditeur",  // 法文
    "청취자",    // 韩文
    "Oyente",    // 西班牙文
];

/// 伤害行没有颜色标记时，数字后面表示「受到伤害」的方向词（其后应是空白）。
///
/// 日文两个方向都是 `から`，不列；韩文按句尾判断，见 [`INCOMING_PHRASES`]。
pub const INCOMING_WORDS: [&str; 5] = [
    "来自", // 中文
    "from", // 英文
    "из",   // 俄文
    "von",  // 德文
    "de",   // 法文、西班牙文
];

/// 伤害行没有颜色标记时，数字后面表示「造成伤害」的方向词（其后应是空白）。
pub const OUTGOING_WORDS: [&str; 6] = [
    "对",   // 中文
    "to",   // 英文
    "на",   // 俄文
    "nach", // 德文
    "à",    // 法文
    "a",    // 西班牙文
];

/// 句中出现即表示「受到伤害」的短语。韩文的方向写在句尾，不在数字后面。
pub const INCOMING_PHRASES: [&str; 1] = ["에 의해 입음"];

/// 句中出现即表示「造成伤害」的短语（韩文）。
pub const OUTGOING_PHRASES: [&str; 1] = ["에게 입힘"];

/// 「对方未命中你」的句尾（去掉尾部空白与一个句号之后比较）。
pub const INCOMING_MISS_MARKERS: [&str; 11] = [
    // 中文（真实日志）
    "完全没有打中你",
    "完全没有击中你",
    // 英文
    "misses you completely",
    // 俄文
    "мимо вашего корабля",
    // 日文
    "あなたを完全に外した",
    // 德文
    "hat Sie völlig verfehlt",
    "verfehlt Sie völlig",
    // 法文（按性别两种）
    "vous a complètement manqué",
    "vous a complètement manquée",
    // 西班牙文
    "falla por mucho",
    // 韩文，另见 INCOMING_MISS_EXCLUSIONS
    "완전히 빗나감",
];

/// 句中含有这些短语时，即使句尾匹配 [`INCOMING_MISS_MARKERS`] 也不算「对方未命中你」。
///
/// 韩文己方未命中的模板是「…을(를) 완전히 빗나감」，句尾与对方未命中相同，只能按宾格助词区分。
/// 客户端可能把「을(를)」换成实际的「을」或「를」（按名字的收音），所以三种写法都列出。
pub const INCOMING_MISS_EXCLUSIONS: [&str; 3] =
    ["을(를) 완전히 빗나감", "을 완전히 빗나감", "를 완전히 빗나감"];

/// 未命中的通用短语：不是「对方未命中你」但含有这些短语的行，归为己方未命中。
pub const MISS_MARKERS: [&str; 9] = [
    // 中文
    "完全没有打中",
    "完全没有击中",
    // 英文（后面有空格，避免匹配到别的词）
    "misses ",
    // 俄文
    "промах",
    // 日文
    "完全に外した",
    // 德文
    "völlig verfehlt",
    // 法文
    "complètement manqué",
    // 西班牙文
    "por mucho",
    // 韩文
    "완전히 빗나감",
];

/// 受到伤害的数字颜色（不区分大小写，不含 `0x` 或 `#` 前缀）。8 种语言相同。
pub const INCOMING_DAMAGE_COLOR: &str = "ffcc0000";

/// 造成伤害的数字颜色。
pub const OUTGOING_DAMAGE_COLOR: &str = "ff00ffff";
