// SPDX-License-Identifier: GPL-3.0-or-later
//
// 情报用语、舰船缩写与虚词表（docs/design-intel-translate.md 6.3 节）。这些表由人维护，随代码审查，
// 不放进星图数据文件。
//
// 来源：
// - shipAliases：参考实现 backend/app/glossary/slang.py，去掉装备与建筑的缩写。右边的英文名在 SDE 里
//   找不到时，TermMatcher 自动不收那一项。`bs`、`bc`、`jf` 只有 2 个字符，按 6.3 节扫描第 4 条永远不会匹配，
//   已删掉（6.3 节末尾允许删 `bs` 与 `bc`；`jf` 同理，回报里说明）。
// - clearWords、noVisualWords：参考实现 backend/app/combatlog/live.py，加两个词的写法 `no visual`。
// - stopWords：参考实现 backend/app/glossary/match.py 的 STOPWORDS 原表。
// - nonPilotWords：stopWords 加参考实现 desktop/eve_local/intel.py 的 _INTEL_WORDS_TEXT 原表，
//   再加 6.3 节列出的 11 个词（原表已有的不重复）。
// - ambiguousShortNames：对照 packaging/eve-static.json（SDE 3720952）列出，见该表的注释。
//
// 另有几个分类字符的工具函数，供术语匹配、分段与人名核对共用（模块内部）。

import Foundation

/// 情报相关的固定词表。
public enum IntelLexicon {
    /// 舰船的缩写或俗称 → SDE 里的英文名（舰船或舰船分组）。键是小写。
    public static let shipAliases: [String: String] = [
        "dic": "Interdictor", "dictor": "Interdictor", "dictors": "Interdictor",
        "hic": "Heavy Interdiction Cruiser", "hics": "Heavy Interdiction Cruiser",
        "hac": "Heavy Assault Cruiser", "hacs": "Heavy Assault Cruiser",
        "ceptor": "Interceptor", "ceptors": "Interceptor", "inty": "Interceptor",
        "t3c": "Strategic Cruiser",
        "t3d": "Tactical Destroyer",
        "logi": "Logistics",
        "dread": "Dreadnought", "dreads": "Dreadnought",
        "fax": "Force Auxiliary",
        "super": "Supercarrier", "supers": "Supercarrier",
        "blops": "Black Ops",
        "bomber": "Stealth Bomber", "bombers": "Stealth Bomber",
        "dessie": "Destroyer", "dessies": "Destroyer",
        "frig": "Frigate", "frigs": "Frigate",
        "rorq": "Rorqual",
        "mach": "Machariel",
        "nado": "Tornado",
        "phoon": "Typhoon",
        "cane": "Hurricane", "canes": "Hurricane",
        "domi": "Dominix",
        "geddon": "Armageddon",
        "apoc": "Apocalypse",
        "mega": "Megathron",
        "vni": "Vexor Navy Issue",
    ]

    /// 「安全」一类的情报用语。
    public static let clearWords: Set<String> = ["clr", "clear", "安全", "无人"]

    /// 「未见」一类的情报用语。`no visual` 是两个词，按词键匹配。
    public static let noVisualWords: Set<String> = ["nv", "novisual", "no visual"]

    /// 英文虚词（参考实现 match.py 的 STOPWORDS，66 个）。只有一个词的术语不匹配这些词。
    public static let stopWords: Set<String> = Set((
        "a an and are as at be but by do for from go had has have he her him his how i if in is it its me my no not "
            + "of off ok on or our out she so than that the their them then there they this to too up us was we were "
            + "what when where who why will with yes you your"
    ).split(separator: " ").map(String.init))

    /// 不当人名的英文词：虚词，加情报里常见的词（参考实现 intel.py 的 _INTEL_WORDS_TEXT），再加 6.3 节的 11 个词。
    public static let nonPilotWords: Set<String> = stopWords.union((
        "avoid gate gates camp camping bubble bubbled bubbles inbound outbound incoming local spike red reds neut "
            + "neuts hostile hostiles fleet gang docked dock undock undocked tether tethered cloaky cloaked cyno titan "
            + "drop ess structure safe moving jumped jumping jump warp warped warping in out at on near via from to and "
            + "or plus x status pos ansi ansiblex keepstar fort citadel astra station anchor anchored roaming roam solo "
            + "small big large medium blops bomber bombers probes probe scanning combat dscan d-scan zkill killboard "
            + "kill killed dead pod podded tackle tackled point pointed scram scrammed log off logged logoff afk "
            // 6.3 节另加的词；与上面重复的由 Set 去重。
            + "wh ess gate gates station hostile hostiles red reds neut neuts"
    ).split(separator: " ").map(String.init))

    /// 也是普通英文词的 4 个字母以上的名称（小写）。只有一个词时，原文首字母大写或后面紧跟 `*` 才算匹配（6.3 节扫描第 5 条）。
    ///
    /// 做法：取已知空间里只由英文字母组成、4 个字母以上的星系名（1,952 个里的 87 个出现在 macOS 的
    /// /usr/share/dict/words 里），去掉专有名词与生僻词，留下聊天里可能以小写普通词出现的。
    /// 星域名按同样办法列入：第 5 条不区分术语的种类，`catch`、`cache` 这类小写普通词不应认成星域。
    /// 情报里常以小写写出的星域（Delve、Fountain、Tribute）与跟舰船同名的 Providence 不列。
    /// 列入星域名是本表在 6.3 节之外的补充，由 WP-B 的回报说明。
    public static let ambiguousShortNames: Set<String> = [
        // 星系（已知空间）
        "abstention", "access", "adroit", "arena", "canard", "celerity", "chivalric", "couth", "decorum", "dour",
        "equity", "erudite", "exit", "forte", "fortitude", "gallant", "gateway", "half", "hare", "lenity",
        "luminaire", "manifest", "mettle", "pain", "perimeter", "pout", "prism", "ratiocinate", "repute", "reset",
        "rigor", "sagacity", "solemn", "steadfast", "tenacity", "toon", "triumph", "utopia", "valiance", "vale",
        "venerate", "weld",
        // 星域
        "branch", "cache", "catch", "curse", "devoid", "domain", "essence", "fade", "genesis", "metropolis",
        "placid", "solitude", "stain", "syndicate",
    ]

    // MARK: - 字符分类（模块内部）

    /// 是否为汉字、假名或谚文。这些文字的名称按「字符键」匹配，也不能出现在人名里。
    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,       // 谚文字母
                 0x3040...0x30FF,       // 平假名、片假名
                 0x3130...0x318F,       // 谚文兼容字母
                 0x31F0...0x31FF,       // 片假名语音扩展
                 0x3400...0x4DBF,       // 汉字扩展 A
                 0x4E00...0x9FFF,       // 汉字
                 0xAC00...0xD7AF,       // 谚文音节
                 0xF900...0xFAFF,       // 兼容汉字
                 0xFF66...0xFF9F,       // 半角片假名
                 0x20000...0x2FFFF:     // 汉字扩展 B 以后
                return true
            default:
                return false
            }
        }
    }

    /// 是否为「词」里的字母或数字：字母或数字，且不是汉字、假名、谚文。
    static func isWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !isCJK(character)
    }

    /// 可以夹在词中间的字符：`'`、`’`、`-`（如 `1DQ1-A`、`HED-GP`）。
    static func isWordJoiner(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "-"
    }

    /// 两个词之间可以单独出现、仍算连续的字符：一个空格或一个引号。
    static func isWordLink(_ character: Character) -> Bool {
        character == " " || "'\"‘’“”".contains(character)
    }

    /// 把名称切成小写的词，用一个空格连接；没有词时返回 nil。规则同术语匹配里的「词」。
    static func wordKey(_ name: String) -> String? {
        let words = splitWords(name)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// 名称里的词（小写）：连续的字母或数字，中间可以夹 `'`、`’`、`-`。
    static func splitWords(_ name: String) -> [String] {
        let characters = Array(name)
        var words: [String] = []
        var index = 0
        while index < characters.count {
            guard isWordCharacter(characters[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count {
                if isWordCharacter(characters[end]) {
                    end += 1
                } else if isWordJoiner(characters[end]), end + 1 < characters.count,
                          isWordCharacter(characters[end + 1]) {
                    end += 2
                } else {
                    break
                }
            }
            words.append(String(characters[index..<end]).lowercased())
            index = end
        }
        return words
    }
}
