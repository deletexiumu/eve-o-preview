// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的测试样例与用例（反馈文档 10.1 节），照搬 macOS 的 CombatLogFixtures.swift 与各个测试文件，
// 两端对同一批样例得出相同的结论。样例全部写成字符串常量，不用测试资源文件。
// 来源：
// - 中文：真实 Gamelogs 的格式。收听者与玩家名、军团与联盟简称都换成虚构的，NPC 与物品名是游戏的公开数据。
// - 日文、俄文：上游的录制样例（已由上游匿名化）。
// - 英文：文件头是真实日志的格式；伤害行与未命中取自上游的测试用例与模板。
// - 德文、法文、西班牙文、韩文：按上游模板（编号 285197～285204）拼出，未经真实客户端核对。
// 上游的样例以 GPL-3.0 发布（EveOPlus/eve-o-preview），与本项目的许可证相同。

mod directory;
mod framer;
mod header;
mod parser;
mod rules;

/// 分隔线。
pub(super) const SEPARATOR: &str = "------------------------------------------------------------";

/// 中文文件头（真实格式，收听者换成虚构的名字）。
pub(super) const ZH_HEADER: [&str; 5] = [
    SEPARATOR,
    "  游戏记录",
    "  收听者: Aurora Vale",
    "  进程开始: 2026.11.20 11:33:46",
    SEPARATOR,
];

/// 登录界面阶段的中文文件头：没有收听者一行（真实格式）。
pub(super) const ZH_HEADER_WITHOUT_LISTENER: [&str; 4] = [
    SEPARATOR,
    "  游戏记录",
    "  进程开始: 2026.11.20 11:33:29",
    SEPARATOR,
];

/// 英文文件头（真实格式）。
pub(super) const EN_HEADER: [&str; 5] = [
    SEPARATOR,
    "  Game Log",
    "  Listener: Aurora Vale",
    "  Session Started: 2026.11.20 09:51:41",
    SEPARATOR,
];

/// 各语言的文件头标题行、收听者标签与开始时间标签。解析不看标题行，德、法、韩、西的标题是占位文字。
pub(super) const HEADER_LABELS: [(&str, &str, &str); 8] = [
    ("Game Log", "Listener", "Session Started"),
    ("游戏记录", "收听者", "进程开始"),
    ("Игровой журнал", "Слушатель", "Сеанс начат"),
    ("ゲームログ", "傍聴者", "セッション開始"),
    ("Spiel-Log", "Empfänger", "Sitzung gestartet"),
    ("Journal de jeu", "Auditeur", "Session commencée"),
    ("게임 로그", "청취자", "세션 시작됨"),
    ("Registro de juego", "Oyente", "Sesión iniciada"),
];

/// 按语言拼一个文件头。`colon` 是标签与名字之间的冒号写法（含空格）。
pub(super) fn header(title: &str, label: &str, session: &str, listener: &str, colon: &str) -> Vec<String> {
    vec![
        SEPARATOR.to_owned(),
        format!("  {title}"),
        format!("  {label}{colon}{listener}"),
        format!("  {session}: 2026.01.01 00:00:00"),
        SEPARATOR.to_owned(),
    ]
}

/// 受到伤害（中文真实格式）。
pub(super) const ZH_INCOMING: &str = "[ 2026.10.22 10:30:13 ] (combat) <color=0xffcc0000><b>19</b> <color=0x77ffffff><font size=10>来自</font> <b><color=0xffffffff>古斯塔斯塔台岗哨 II*</b><font size=10><color=0x77ffffff> - 穿透";
/// 造成伤害。
pub(super) const ZH_OUTGOING: &str = "[ 2026.10.22 10:30:49 ] (combat) <color=0xff00ffff><b>117</b> <color=0x77ffffff><font size=10>对</font> <b><color=0xffffffff>灾难皮希伊 粉碎者*</b><font size=10><color=0x77ffffff> - 胡蜂 II* - 命中";
/// 数字为 0 的受到伤害。
pub(super) const ZH_INCOMING_ZERO: &str = "[ 2026.10.22 10:31:02 ] (combat) <color=0xffcc0000><b>0</b> <color=0x77ffffff><font size=10>来自</font> <b><color=0xffffffff>灾难皮希伊 粉碎者*</b><font size=10><color=0x77ffffff> - 擦过";
/// 对方未命中。
pub(super) const ZH_INCOMING_MISS: &str = "[ 2026.10.22 10:30:25 ] (combat) 灾难皮希伊 粉碎者*完全没有打中你";
/// 对方的武器未命中（上游模板的说法「击中」）。
pub(super) const ZH_INCOMING_MISS_WEAPON: &str =
    "[ 2026.10.22 10:30:26 ] (combat) Sample Pilot的Sample Module完全没有击中你";
/// 己方未命中。
pub(super) const ZH_OUTGOING_MISS: &str =
    "[ 2026.10.22 10:30:40 ] (combat) 你的胡蜂 II*完全没有打中灾难皮希伊 粉碎者* - 胡蜂 II*";
/// 跃迁扰断（反例）：以 `<color=0x77ffffff>` 开头，没有开头的数字。玩家名与简称已换成虚构的。
pub(super) const ZH_WARP_SCRAMBLE: &str = "[ 2026.10.28 14:35:01 ] (combat) <color=0x77ffffff><font size=10></font> <color=0xffffffff><b><font size=14><color=0xFFFFCC66> <u><b>长尾鲛级舰队型*</b></u></color></font><font size=14><color=0xFFFFCC66> [AAAA]</color></font><font size=12><color=0xFFFFFFCC> [<b>BBBB</b>]</color></font> <font size=12><color=0xFFFFFFFF> <b>Sample Pilot</b> -</color></font></b> <color=0xffffffff><b>试图跃迁扰断</b><color=0x77ffffff><font size=10> <b><color=0xffffffff></font><font size=14><color=0xFFFFCC66> <u><b>冲锋者级*</b></u></color></font><font size=14><color=0xFFFFCC66> [CCCC]</color></font><font size=12><color=0xFFFFFFCC> [<b>DDDD</b>]</color></font> <font size=12><color=0xFFFFFFFF> <b>Other Pilot</b> -</color></font>";
/// hint 类别。
pub(super) const ZH_HINT: &str = "[ 2026.11.20 11:33:51 ] (hint) 正在尝试加入一个频道";
/// None 类别（上游样例里出现过）。
pub(super) const RU_NONE_CATEGORY: &str = "[ 2026.01.01 00:00:21 ] (None) Выход из дока <localized hint=\"Sample Station\">Sample Station* в звездную систему <localized hint=\"Jita\">Jita*.";

/// 日文受到伤害：介词是 `から`，颜色是 0xffcc0000。
pub(super) const JA_INCOMING: &str = "[ 2026.01.01 00:34:16 ] (combat) <color=0xffcc0000><b>40</b> <color=0x77ffffff><font size=10>から</font> <b><color=0xffffffff><localized hint=\"Interfering Phase-IV Legionary\">インターフェアフェーズIVリージョナリー*</b><font size=10><color=0x77ffffff> - 直撃";
/// 日文造成伤害：介词同样是 `から`，只有颜色不同。
pub(super) const JA_OUTGOING: &str = "[ 2026.01.01 00:34:23 ] (combat) <color=0xff00ffff><b>492</b> <color=0x77ffffff><font size=10>から</font> <b><color=0xffffffff><localized hint=\"Overmind Destructor Delta\">オーバーマインド・デストラクター・デルタ*</b><font size=10><color=0x77ffffff> - <localized hint=\"Nova Light Missile\">ノヴァライトミサイル*</localized> - 直撃";
/// 去掉颜色标记的日文伤害行：判断不了方向，应归为 OtherCombat。
pub(super) const JA_NO_COLOR: &str = "[ 2026.01.01 00:34:16 ] (combat) <b>40</b> <color=0x77ffffff><font size=10>から</font> <b><color=0xffffffff>インターフェアフェーズIVリージョナリー*</b>";
/// 日文对方未命中。
pub(super) const JA_INCOMING_MISS: &str = "[ 2026.01.01 00:04:47 ] (combat) <localized hint=\"Vexing Phase-II Legionary\">ヴェックスフェーズIIリージョナリー*の攻撃はあなたを完全に外した";
/// 日文己方未命中。
pub(super) const JA_OUTGOING_MISS: &str =
    "[ 2026.01.01 00:04:48 ] (combat) あなたのSample Moduleの攻撃はSample Pilotを完全に外した";

/// 俄文受到伤害。
pub(super) const RU_INCOMING: &str = "[ 2026.01.01 00:01:37 ] (combat) <color=0xffcc0000><b>130</b> <color=0x77ffffff><font size=10>из</font> <b><color=0xffffffff><localized hint=\"Overmind Destructor Delta\">Overmind Destructor Delta*</b><font size=10><color=0x77ffffff> - Попал";
/// 俄文造成伤害。
pub(super) const RU_OUTGOING: &str = "[ 2026.01.01 00:01:44 ] (combat) <color=0xff00ffff><b>983</b> <color=0x77ffffff><font size=10>на</font> <b><color=0xffffffff><localized hint=\"Overmind Destructor Delta\">Overmind Destructor Delta*</b><font size=10><color=0x77ffffff> - <localized hint=\"Nova Light Missile\">Nova Light Missile*</localized> - Попал";
/// 俄文对方未命中（上游模板，未经真实客户端核对）。
pub(super) const RU_INCOMING_MISS: &str =
    "[ 2026.01.01 00:01:50 ] (combat) Sample Pilot: промах мимо вашего корабля";
/// 俄文己方未命中（上游模板，未经真实客户端核对）。
pub(super) const RU_OUTGOING_MISS: &str =
    "[ 2026.01.01 00:01:51 ] (combat) Ваше орудие Sample Module промахнулось мимо Sample Pilot";

/// 英文受到伤害。
pub(super) const EN_INCOMING: &str = "[ 2026.01.01 00:00:10 ] (combat) <color=0xffcc0000><b>214</b> <color=0x77ffffff><font size=10>from <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module";
/// 英文造成伤害。
pub(super) const EN_OUTGOING: &str = "[ 2026.01.01 00:00:11 ] (combat) <color=0xff00ffff><b>214</b> <color=0x77ffffff><font size=10>to <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module";
/// 英文对方未命中。
pub(super) const EN_INCOMING_MISS: &str =
    "[ 2026.01.01 00:00:12 ] (combat) Sample Pilot misses you completely";
/// 英文对方的武器未命中。
pub(super) const EN_INCOMING_MISS_WEAPON: &str =
    "[ 2026.01.01 00:00:13 ] (combat) Sample Module belonging to Sample Pilot misses you completely";
/// 英文己方未命中。
pub(super) const EN_OUTGOING_MISS: &str =
    "[ 2026.01.01 00:00:14 ] (combat) Your Sample Module misses Sample Pilot completely";

/// 一种只有模板的语言的样例：名字、受到与造成伤害时数字后面的文字（含标记）、两种未命中的正文。
pub(super) struct TemplateLanguage {
    /// 语言名，用于失败时的说明。
    pub name: &'static str,
    /// 受到伤害时数字后面的方向文字。
    pub incoming_middle: &'static str,
    /// 造成伤害时数字后面的方向文字。
    pub outgoing_middle: &'static str,
    /// 对方未命中的正文。
    pub incoming_miss: &'static str,
    /// 己方未命中的正文。
    pub outgoing_miss: &'static str,
}

/// 4 种只有模板的语言。韩文的方向写在句尾，所以「数字后面的文字」是整句的其余部分。
pub(super) const TEMPLATE_LANGUAGES: [TemplateLanguage; 4] = [
    TemplateLanguage {
        name: "de",
        incoming_middle: "<color=0x77ffffff><font size=10>von <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
        outgoing_middle: "<color=0x77ffffff><font size=10>nach <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
        incoming_miss: "Sample Module von Sample Pilot hat Sie völlig verfehlt",
        outgoing_miss: "Ihr Sample Module hat Sample Pilot völlig verfehlt",
    },
    TemplateLanguage {
        name: "fr",
        incoming_middle: "<color=0x77ffffff><font size=10>de <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
        outgoing_middle: "<color=0x77ffffff><font size=10>à <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
        incoming_miss: "L'arme Sample Module appartenant à Sample Pilot vous a complètement manquée.",
        outgoing_miss: "Votre Sample Module a complètement manqué Sample Pilot",
    },
    TemplateLanguage {
        name: "es",
        incoming_middle: "<color=0x77ffffff><font size=10>de <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
        outgoing_middle: "<color=0x77ffffff><font size=10>a <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
        incoming_miss: "Sample Module, de Sample Pilot, falla por mucho.",
        outgoing_miss: "Tu Sample Module no acierta en Sample Pilot por mucho.",
    },
    TemplateLanguage {
        name: "ko",
        incoming_middle: "<color=0x77ffffff><font size=10>의 피해를 <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff>에 의해 입음 - Sample Module",
        outgoing_middle: "<color=0x77ffffff><font size=10>의 피해를 <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff>에게 입힘 - Sample Module",
        incoming_miss: "Sample Pilot의 Sample Module이(가) 완전히 빗나감",
        outgoing_miss: "Sample Module이(가) Sample Pilot을(를) 완전히 빗나감",
    },
];

/// 用固定的时间与正文拼一行 combat 日志。
pub(super) fn combat(body: &str) -> String {
    format!("[ 2026.01.01 00:00:00 ] (combat) {body}")
}
