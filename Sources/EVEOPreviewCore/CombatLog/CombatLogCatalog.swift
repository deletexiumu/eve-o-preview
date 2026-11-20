// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的多语言短语表（反馈文档 7.5 节、7.6 节）。
// 取自上游的 EveLogLanguageCatalog.cs（模板编号 285197～285204）与本机日志的真实格式。
// 日志的语言与界面语言无关：8 种语言的短语同时生效，不设语言选项。
// 匹配时一律不区分大小写；短语表只做前缀、后缀与子串比较，不用正则表达式（7.10 节）。

import Foundation

/// 游戏日志的多语言短语表。
public enum CombatLogCatalog {
    /// 文件头里收听者一行的标签，后面紧跟半角或全角冒号。
    ///
    /// 英文与中文有本机日志为证（L5），俄文与日文有上游的录制样例，其余 4 种取自上游模板。
    public static let listenerLabels: [String] = [
        "Listener",     // 英文
        "收听者",        // 中文
        "Слушатель",    // 俄文
        "傍聴者",        // 日文
        "Empfänger",    // 德文
        "Auditeur",     // 法文
        "청취자",         // 韩文
        "Oyente",       // 西班牙文
    ]

    /// 伤害行没有颜色标记时，数字后面表示「受到伤害」的方向词（其后应是空白）。
    ///
    /// 日文两个方向都是 `から`，不列；韩文按句尾判断，见 `incomingPhrases`。
    public static let incomingWords: [String] = [
        "来自",   // 中文
        "from",  // 英文
        "из",    // 俄文
        "von",   // 德文
        "de",    // 法文、西班牙文
    ]

    /// 伤害行没有颜色标记时，数字后面表示「造成伤害」的方向词（其后应是空白）。
    public static let outgoingWords: [String] = [
        "对",     // 中文
        "to",    // 英文
        "на",    // 俄文
        "nach",  // 德文
        "à",     // 法文
        "a",     // 西班牙文
    ]

    /// 句中出现即表示「受到伤害」的短语。韩文的方向写在句尾，不在数字后面。
    public static let incomingPhrases: [String] = ["에 의해 입음"]

    /// 句中出现即表示「造成伤害」的短语（韩文）。
    public static let outgoingPhrases: [String] = ["에게 입힘"]

    /// 「对方未命中你」的句尾（去掉尾部空白与一个句号之后比较）。
    public static let incomingMissMarkers: [String] = [
        "完全没有打中你", "完全没有击中你",                       // 中文（本机日志 L8）
        "misses you completely",                              // 英文
        "мимо вашего корабля",                                // 俄文
        "あなたを完全に外した",                                 // 日文
        "hat Sie völlig verfehlt", "verfehlt Sie völlig",     // 德文
        "vous a complètement manqué", "vous a complètement manquée", // 法文（按性别两种）
        "falla por mucho",                                    // 西班牙文
        "완전히 빗나감",                                        // 韩文，另见 incomingMissExclusions
    ]

    /// 句中含有这些短语时，即使句尾匹配 `incomingMissMarkers` 也不算「对方未命中你」。
    ///
    /// 韩文己方未命中的模板是「…을(를) 완전히 빗나감」，句尾与对方未命中相同，只能按宾格助词区分。
    /// 客户端可能把「을(를)」换成实际的「을」或「를」（按名字的收音），所以三种写法都列出。
    /// 对方未命中的模板是「…이(가) 완전히 빗나감」，宾格助词不会紧贴在句尾短语前。
    public static let incomingMissExclusions: [String] = [
        "을(를) 완전히 빗나감", "을 완전히 빗나감", "를 완전히 빗나감",
    ]

    /// 未命中的通用短语：不是「对方未命中你」但含有这些短语的行，归为己方未命中。
    public static let missMarkers: [String] = [
        "完全没有打中", "完全没有击中",   // 中文
        "misses ",                     // 英文
        "промах",                      // 俄文
        "完全に外した",                  // 日文
        "völlig verfehlt",             // 德文
        "complètement manqué",         // 法文
        "por mucho",                   // 西班牙文
        "완전히 빗나감",                  // 韩文
    ]

    /// 受到伤害的数字颜色（不区分大小写，不含 `0x` 或 `#` 前缀）。8 种语言相同（L7、L14）。
    public static let incomingDamageColor = "ffcc0000"

    /// 造成伤害的数字颜色。
    public static let outgoingDamageColor = "ff00ffff"
}
