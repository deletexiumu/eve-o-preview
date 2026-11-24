// SPDX-License-Identifier: GPL-3.0-or-later
//
// 情报用语、舰船缩写与虚词表，对应 macOS 的 IntelLexicon.swift（设计文档 6.3 节）。这些表由人维护，随代码审查，
// 不放进星图数据文件；两个平台的表必须一致，改动时同步改 macOS 的那一份。
//
// 来源（详见 macOS 文件的说明）：
// - SHIP_ALIASES：参考实现的俗称表，去掉装备与建筑的缩写；`bs`、`bc`、`jf` 只有 2 个字符，永远不会匹配，已删掉。
// - CLEAR_WORDS、NO_VISUAL_WORDS：参考实现的情报用语，加两个词的写法 `no visual`。
// - STOP_WORDS：参考实现的 66 个英文虚词。
// - NON_PILOT_WORDS：虚词加情报里常见的词，再加 6.3 节的 11 个词与常见的致意、道别。
// - AMBIGUOUS_SHORT_NAMES：也是普通英文词的星系与星域名（对照 SDE 3720952 列出）。
// 另有几个分类字符的工具函数，供术语匹配、分段与人名核对共用。

//! 情报相关的固定词表与字符分类。

// 拦截舰与重型拦截巡洋舰：情报里最要紧的两类，单复数都收。
// 截击舰的几种叫法。
// 三代战略巡洋舰与战术驱逐舰。
// 旗舰级：无畏、战力辅助舰、超级航母、黑隐特勤舰。
// 隐形轰炸舰与常见舰种的口语。
// 具体舰船的简称。
/// 舰船的缩写或俗称 → SDE 里的英文名（舰船或舰船分组）。键是小写。
pub const SHIP_ALIASES: [(&str, &str); 36] = [
    ("dic", "Interdictor"),
    ("dictor", "Interdictor"),
    ("dictors", "Interdictor"),
    ("hic", "Heavy Interdiction Cruiser"),
    ("hics", "Heavy Interdiction Cruiser"),
    ("hac", "Heavy Assault Cruiser"),
    ("hacs", "Heavy Assault Cruiser"),
    ("ceptor", "Interceptor"),
    ("ceptors", "Interceptor"),
    ("inty", "Interceptor"),
    ("t3c", "Strategic Cruiser"),
    ("t3d", "Tactical Destroyer"),
    ("logi", "Logistics"),
    ("dread", "Dreadnought"),
    ("dreads", "Dreadnought"),
    ("fax", "Force Auxiliary"),
    ("super", "Supercarrier"),
    ("supers", "Supercarrier"),
    ("blops", "Black Ops"),
    ("bomber", "Stealth Bomber"),
    ("bombers", "Stealth Bomber"),
    ("dessie", "Destroyer"),
    ("dessies", "Destroyer"),
    ("frig", "Frigate"),
    ("frigs", "Frigate"),
    ("rorq", "Rorqual"),
    ("mach", "Machariel"),
    ("nado", "Tornado"),
    ("phoon", "Typhoon"),
    ("cane", "Hurricane"),
    ("canes", "Hurricane"),
    ("domi", "Dominix"),
    ("geddon", "Armageddon"),
    ("apoc", "Apocalypse"),
    ("mega", "Megathron"),
    ("vni", "Vexor Navy Issue"),
];

/// 「安全」一类的情报用语。
pub const CLEAR_WORDS: [&str; 4] = ["clr", "clear", "安全", "无人"];

/// 「未见」一类的情报用语。`no visual` 是两个词，按词键匹配。
pub const NO_VISUAL_WORDS: [&str; 3] = ["nv", "novisual", "no visual"];

/// 中文情报用语前面的否定字：「不安全」「没无人」里的用语不算。
pub const CJK_NEGATIONS: [char; 5] = ['不', '非', '未', '没', '沒'];
/// 往回看几个字符找否定字：2 个时「不太安全」「没有安全」也算否定。
pub const CJK_NEGATION_LOOK_BACK: usize = 2;

/// 是日常中文词的星系与星域译名：作为字符键匹配时，后面紧跟 `*`，或前后都不紧挨汉字、假名、谚文时才算。
/// 音译名（如 Perimeter 的「皮尔米特」）不列，照常不看边界。对应的英文名：星系 Exit、Reset、Gateway、Forte、
/// Utopia、Central Point、Dead End、Polaris；星域 Cache、Devoid、Stain、Branch、Domain、Lonetrek、Outer Ring。
pub const COMMON_WORD_LOCALIZED_NAMES: [&str; 15] = [
    "出口",
    "重置",
    "通路",
    "福特",
    "乌托邦",
    "中心点",
    "绝境",
    "北极星",
    "地窖",
    "破碎",
    "混浊",
    "血脉",
    "多美",
    "长征",
    "外环",
];

/// 只有大写或带 `*` 才认的舰船名（小写）：3 个字母、又是常见普通词的舰船名。
pub const CASE_SENSITIVE_SHIP_NAMES: [&str; 4] = ["sin", "imp", "ark", "hel"];

/// 英文虚词（66 个）。只有一个词的术语不匹配这些词。
pub const STOP_WORDS: &str = "a an and are as at be but by do for from go had has have he her him his how i if in is it its me my no not \
of off ok on or our out she so than that the their them then there they this to too up us was we were \
what when where who why will with yes you your";

/// 不当人名的英文词（虚词之外的部分）：情报里常见的词、6.3 节另加的词，以及聊天里的致意与道别。
pub const NON_PILOT_EXTRA_WORDS: &str = "avoid gate gates camp camping bubble bubbled bubbles inbound outbound incoming local spike red reds neut \
neuts hostile hostiles fleet gang docked dock undock undocked tether tethered cloaky cloaked cyno titan \
drop ess structure safe moving jumped jumping jump warp warped warping in out at on near via from to and \
or plus x status pos ansi ansiblex keepstar fort citadel astra station anchor anchored roaming roam solo \
small big large medium blops bomber bombers probes probe scanning combat dscan d-scan zkill killboard \
kill killed dead pod podded tackle tackled point pointed scram scrammed log off logged logoff afk \
wh ess gate gates station hostile hostiles red reds neut neuts \
o7 7o o/ \\o ty thx tnx gl gg";

/// 也是普通英文词的 4 个字母以上的名称（小写）。只有一个词时，原文首字母大写或后面紧跟 `*` 才算匹配。
pub const AMBIGUOUS_SHORT_NAMES: [&str; 56] = [
    // 星系（已知空间）
    "abstention",
    "access",
    "adroit",
    "arena",
    "canard",
    "celerity",
    "chivalric",
    "couth",
    "decorum",
    "dour",
    "equity",
    "erudite",
    "exit",
    "forte",
    "fortitude",
    "gallant",
    "gateway",
    "half",
    "hare",
    "lenity",
    "luminaire",
    "manifest",
    "mettle",
    "pain",
    "perimeter",
    "pout",
    "prism",
    "ratiocinate",
    "repute",
    "reset",
    "rigor",
    "sagacity",
    "solemn",
    "steadfast",
    "tenacity",
    "toon",
    "triumph",
    "utopia",
    "valiance",
    "vale",
    "venerate",
    "weld",
    // 星域
    "branch",
    "cache",
    "catch",
    "curse",
    "devoid",
    "domain",
    "essence",
    "fade",
    "genesis",
    "metropolis",
    "placid",
    "solitude",
    "stain",
    "syndicate",
];

/// 是否为虚词。
pub fn is_stop_word(word: &str) -> bool {
    STOP_WORDS.split(' ').any(|w| w == word)
}

/// 是否为不当人名的词：虚词，或情报里常见的词。
pub fn is_non_pilot_word(word: &str) -> bool {
    is_stop_word(word) || NON_PILOT_EXTRA_WORDS.split(' ').any(|w| w == word)
}

/// 是否为汉字、假名或谚文。这些文字的名称按「字符键」匹配，也不能出现在人名里。
pub fn is_cjk(c: char) -> bool {
    matches!(
        u32::from(c),
        0x1100..=0x11FF       // 谚文字母
            | 0x3040..=0x30FF // 平假名、片假名
            | 0x3130..=0x318F // 谚文兼容字母
            | 0x31F0..=0x31FF // 片假名语音扩展
            | 0x3400..=0x4DBF // 汉字扩展 A
            | 0x4E00..=0x9FFF // 汉字
            | 0xAC00..=0xD7AF // 谚文音节
            | 0xF900..=0xFAFF // 兼容汉字
            | 0xFF66..=0xFF9F // 半角片假名
            | 0x20000..=0x2FFFF // 汉字扩展 B 以后
    )
}

/// 是否为「词」里的字母或数字：字母或数字，且不是汉字、假名、谚文。
pub fn is_word_character(c: char) -> bool {
    c.is_alphanumeric() && !is_cjk(c)
}

/// 可以夹在词中间的字符：`'`、`’`、`-`（如 `1DQ1-A`、`HED-GP`）。
pub fn is_word_joiner(c: char) -> bool {
    matches!(c, '\'' | '’' | '-')
}

/// 两个词之间可以单独出现、仍算连续的字符：一个空格或一个引号。
pub fn is_word_link(c: char) -> bool {
    matches!(c, ' ' | '\'' | '"' | '‘' | '’' | '“' | '”')
}

/// 把名称切成小写的词，用一个空格连接；没有词时返回 `None`。规则同术语匹配里的「词」。
pub fn word_key(name: &str) -> Option<String> {
    let words = split_words(name);
    (!words.is_empty()).then(|| words.join(" "))
}

/// 名称里的词（小写）：连续的字母或数字，中间可以夹 `'`、`’`、`-`。
pub fn split_words(name: &str) -> Vec<String> {
    let chars: Vec<char> = name.chars().collect();
    let mut words = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        if !is_word_character(chars[index]) {
            index += 1;
            continue;
        }
        let mut end = index + 1;
        while end < chars.len() {
            if is_word_character(chars[end]) {
                end += 1;
            } else if is_word_joiner(chars[end]) && end + 1 < chars.len() && is_word_character(chars[end + 1])
            {
                end += 2;
            } else {
                break;
            }
        }
        words.push(chars[index..end].iter().collect::<String>().to_lowercase());
        index = end;
    }
    words
}
