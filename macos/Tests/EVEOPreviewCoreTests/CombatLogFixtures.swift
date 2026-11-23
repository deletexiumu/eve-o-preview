// SPDX-License-Identifier: GPL-3.0-or-later
//
// 游戏日志的测试样例（反馈文档 10.1 节）。全部写成字符串常量，不用测试资源文件。
// 来源：
// - 中文：本机 Gamelogs 的真实格式（2026-11-20 只读抽取，L5～L9）。收听者与玩家名、军团与联盟简称都换成虚构的，
//   NPC 与物品名是游戏的公开数据，保留原文。
// - 日文、俄文：上游的录制样例 japanese-damage.txt、japanese-client.txt、russian-client.txt（已由上游匿名化）。
// - 英文：文件头是本机日志的真实格式；伤害行与未命中取自上游的测试用例与模板 localization-templates.json。
// - 德文、法文、西班牙文、韩文：按上游模板（编号 285197～285204）拼出，由模板推得，未经真实客户端核对（V15）。
// 上游的样例以 GPL-3.0 发布（EveOPlus/eve-o-preview），与本项目的许可证相同。

/// 游戏日志的测试样例。
enum CombatLogFixtures {
    // MARK: - 文件头

    /// 中文文件头（本机真实格式，收听者换成虚构的名字）。
    static let zhHeader = [
        "------------------------------------------------------------",
        "  游戏记录",
        "  收听者: Aurora Vale",
        "  进程开始: 2026.11.20 11:33:46",
        "------------------------------------------------------------",
    ]

    /// 登录界面阶段的中文文件头：没有收听者一行（L3，本机真实格式）。
    static let zhHeaderWithoutListener = [
        "------------------------------------------------------------",
        "  游戏记录",
        "  进程开始: 2026.11.20 11:33:29",
        "------------------------------------------------------------",
    ]

    /// 英文文件头（本机真实格式）。
    static let enHeader = [
        "------------------------------------------------------------",
        "  Game Log",
        "  Listener: Aurora Vale",
        "  Session Started: 2026.11.20 09:51:41",
        "------------------------------------------------------------",
    ]

    /// 各语言的文件头标题行与收听者标签。中、英为本机日志，俄、日为上游录制样例，其余的标签与开始时间取自上游模板。
    /// 解析不看标题行，德、法、韩、西 4 种语言的标题是占位文字，不是客户端的原文。
    static let headerLabels: [(title: String, label: String, session: String)] = [
        ("Game Log", "Listener", "Session Started"),
        ("游戏记录", "收听者", "进程开始"),
        ("Игровой журнал", "Слушатель", "Сеанс начат"),
        ("ゲームログ", "傍聴者", "セッション開始"),
        ("Spiel-Log", "Empfänger", "Sitzung gestartet"),
        ("Journal de jeu", "Auditeur", "Session commencée"),
        ("게임 로그", "청취자", "세션 시작됨"),
        ("Registro de juego", "Oyente", "Sesión iniciada"),
    ]

    /// 按语言拼一个文件头。
    static func header(title: String, label: String, session: String, listener: String,
                       colon: String = ": ") -> [String] {
        [
            "------------------------------------------------------------",
            "  \(title)",
            "  \(label)\(colon)\(listener)",
            "  \(session): 2026.01.01 00:00:00",
            "------------------------------------------------------------",
        ]
    }

    // MARK: - 中文（本机真实格式）

    /// 受到伤害。
    static let zhIncoming = "[ 2026.10.22 10:30:13 ] (combat) <color=0xffcc0000><b>19</b> <color=0x77ffffff><font size=10>来自</font> <b><color=0xffffffff>古斯塔斯塔台岗哨 II*</b><font size=10><color=0x77ffffff> - 穿透"
    /// 造成伤害。
    static let zhOutgoing = "[ 2026.10.22 10:30:49 ] (combat) <color=0xff00ffff><b>117</b> <color=0x77ffffff><font size=10>对</font> <b><color=0xffffffff>灾难皮希伊 粉碎者*</b><font size=10><color=0x77ffffff> - 胡蜂 II* - 命中"
    /// 数字为 0 的受到伤害（L7）。
    static let zhIncomingZero = "[ 2026.10.22 10:31:02 ] (combat) <color=0xffcc0000><b>0</b> <color=0x77ffffff><font size=10>来自</font> <b><color=0xffffffff>灾难皮希伊 粉碎者*</b><font size=10><color=0x77ffffff> - 擦过"
    /// 对方未命中（L8）。
    static let zhIncomingMiss = "[ 2026.10.22 10:30:25 ] (combat) 灾难皮希伊 粉碎者*完全没有打中你"
    /// 对方的武器未命中（上游模板 285202 的说法「击中」）。
    static let zhIncomingMissWeapon = "[ 2026.10.22 10:30:26 ] (combat) Sample Pilot的Sample Module完全没有击中你"
    /// 己方未命中。
    static let zhOutgoingMiss = "[ 2026.10.22 10:30:40 ] (combat) 你的胡蜂 II*完全没有打中灾难皮希伊 粉碎者* - 胡蜂 II*"
    /// 跃迁扰断（反例，L9）：以 `<color=0x77ffffff>` 开头，没有开头的数字。玩家名与简称已换成虚构的。
    static let zhWarpScramble = "[ 2026.10.28 14:35:01 ] (combat) <color=0x77ffffff><font size=10></font> <color=0xffffffff><b><font size=14><color=0xFFFFCC66> <u><b>长尾鲛级舰队型*</b></u></color></font><font size=14><color=0xFFFFCC66> [AAAA]</color></font><font size=12><color=0xFFFFFFCC> [<b>BBBB</b>]</color></font> <font size=12><color=0xFFFFFFFF> <b>Sample Pilot</b> -</color></font></b> <color=0xffffffff><b>试图跃迁扰断</b><color=0x77ffffff><font size=10> <b><color=0xffffffff></font><font size=14><color=0xFFFFCC66> <u><b>冲锋者级*</b></u></color></font><font size=14><color=0xFFFFCC66> [CCCC]</color></font><font size=12><color=0xFFFFFFCC> [<b>DDDD</b>]</color></font> <font size=12><color=0xFFFFFFFF> <b>Other Pilot</b> -</color></font>"
    /// hint 类别。
    static let zhHint = "[ 2026.11.20 11:33:51 ] (hint) 正在尝试加入一个频道"
    /// None 类别（上游样例里出现过）。
    static let ruNoneCategory = "[ 2026.01.01 00:00:21 ] (None) Выход из дока <localized hint=\"Sample Station\">Sample Station* в звездную систему <localized hint=\"Jita\">Jita*."

    // MARK: - 日文（上游录制样例 japanese-damage.txt、japanese-client.txt）

    /// 受到伤害：介词是 `から`，颜色是 0xffcc0000。
    static let jaIncoming = "[ 2026.01.01 00:34:16 ] (combat) <color=0xffcc0000><b>40</b> <color=0x77ffffff><font size=10>から</font> <b><color=0xffffffff><localized hint=\"Interfering Phase-IV Legionary\">インターフェアフェーズIVリージョナリー*</b><font size=10><color=0x77ffffff> - 直撃"
    /// 造成伤害：介词同样是 `から`，只有颜色不同。
    static let jaOutgoing = "[ 2026.01.01 00:34:23 ] (combat) <color=0xff00ffff><b>492</b> <color=0x77ffffff><font size=10>から</font> <b><color=0xffffffff><localized hint=\"Overmind Destructor Delta\">オーバーマインド・デストラクター・デルタ*</b><font size=10><color=0x77ffffff> - <localized hint=\"Nova Light Missile\">ノヴァライトミサイル*</localized> - 直撃"
    /// 去掉颜色标记的日文伤害行：判断不了方向，应归为 otherCombat。
    static let jaNoColor = "[ 2026.01.01 00:34:16 ] (combat) <b>40</b> <color=0x77ffffff><font size=10>から</font> <b><color=0xffffffff>インターフェアフェーズIVリージョナリー*</b>"
    /// 对方未命中（japanese-client.txt）。
    static let jaIncomingMiss = "[ 2026.01.01 00:04:47 ] (combat) <localized hint=\"Vexing Phase-II Legionary\">ヴェックスフェーズIIリージョナリー*の攻撃はあなたを完全に外した"
    /// 己方未命中（上游模板 285200）。
    static let jaOutgoingMiss = "[ 2026.01.01 00:04:48 ] (combat) あなたのSample Moduleの攻撃はSample Pilotを完全に外した"

    // MARK: - 俄文（上游录制样例 russian-client.txt）

    /// 受到伤害。
    static let ruIncoming = "[ 2026.01.01 00:01:37 ] (combat) <color=0xffcc0000><b>130</b> <color=0x77ffffff><font size=10>из</font> <b><color=0xffffffff><localized hint=\"Overmind Destructor Delta\">Overmind Destructor Delta*</b><font size=10><color=0x77ffffff> - Попал"
    /// 造成伤害。
    static let ruOutgoing = "[ 2026.01.01 00:01:44 ] (combat) <color=0xff00ffff><b>983</b> <color=0x77ffffff><font size=10>на</font> <b><color=0xffffffff><localized hint=\"Overmind Destructor Delta\">Overmind Destructor Delta*</b><font size=10><color=0x77ffffff> - <localized hint=\"Nova Light Missile\">Nova Light Missile*</localized> - Попал"
    /// 对方未命中（上游模板 285203，未经真实客户端核对）。
    static let ruIncomingMiss = "[ 2026.01.01 00:01:50 ] (combat) Sample Pilot: промах мимо вашего корабля"
    /// 己方未命中（上游模板 285200，未经真实客户端核对）。
    static let ruOutgoingMiss = "[ 2026.01.01 00:01:51 ] (combat) Ваше орудие Sample Module промахнулось мимо Sample Pilot"

    // MARK: - 英文（上游测试用例与模板）

    /// 受到伤害。
    static let enIncoming = "[ 2026.01.01 00:00:10 ] (combat) <color=0xffcc0000><b>214</b> <color=0x77ffffff><font size=10>from <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module"
    /// 造成伤害。
    static let enOutgoing = "[ 2026.01.01 00:00:11 ] (combat) <color=0xff00ffff><b>214</b> <color=0x77ffffff><font size=10>to <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module"
    /// 对方未命中。
    static let enIncomingMiss = "[ 2026.01.01 00:00:12 ] (combat) Sample Pilot misses you completely"
    /// 对方的武器未命中。
    static let enIncomingMissWeapon = "[ 2026.01.01 00:00:13 ] (combat) Sample Module belonging to Sample Pilot misses you completely"
    /// 己方未命中。
    static let enOutgoingMiss = "[ 2026.01.01 00:00:14 ] (combat) Your Sample Module misses Sample Pilot completely"

    // MARK: - 德、法、西、韩（由上游模板推得，未经真实客户端核对）

    /// 一种语言的伤害行与对方未命中的样例。
    struct TemplateLanguage {
        /// 语言名，用于测试的说明。
        var name: String
        /// 受到伤害时数字后面的方向文字（含标记）。
        var incomingMiddle: String
        /// 造成伤害时数字后面的方向文字（含标记）。
        var outgoingMiddle: String
        /// 对方未命中的正文。
        var incomingMiss: String
        /// 己方未命中的正文。
        var outgoingMiss: String
    }

    /// 4 种只有模板的语言。韩文的方向写在句尾，所以「数字后面的文字」是整句的其余部分。
    static let templateLanguages: [TemplateLanguage] = [
        TemplateLanguage(
            name: "de",
            incomingMiddle: "<color=0x77ffffff><font size=10>von <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
            outgoingMiddle: "<color=0x77ffffff><font size=10>nach <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
            incomingMiss: "Sample Module von Sample Pilot hat Sie völlig verfehlt",
            outgoingMiss: "Ihr Sample Module hat Sample Pilot völlig verfehlt"),
        TemplateLanguage(
            name: "fr",
            incomingMiddle: "<color=0x77ffffff><font size=10>de <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
            outgoingMiddle: "<color=0x77ffffff><font size=10>à <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
            incomingMiss: "L'arme Sample Module appartenant à Sample Pilot vous a complètement manquée.",
            outgoingMiss: "Votre Sample Module a complètement manqué Sample Pilot"),
        TemplateLanguage(
            name: "es",
            incomingMiddle: "<color=0x77ffffff><font size=10>de <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
            outgoingMiddle: "<color=0x77ffffff><font size=10>a <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff> - Sample Module",
            incomingMiss: "Sample Module, de Sample Pilot, falla por mucho.",
            outgoingMiss: "Tu Sample Module no acierta en Sample Pilot por mucho."),
        TemplateLanguage(
            name: "ko",
            incomingMiddle: "<color=0x77ffffff><font size=10>의 피해를 <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff>에 의해 입음 - Sample Module",
            outgoingMiddle: "<color=0x77ffffff><font size=10>의 피해를 <b><color=0xffffffff>Sample Pilot [SAMPLE](Rifter)</b><font size=10><color=0x77ffffff>에게 입힘 - Sample Module",
            incomingMiss: "Sample Pilot의 Sample Module이(가) 완전히 빗나감",
            outgoingMiss: "Sample Module이(가) Sample Pilot을(를) 완전히 빗나감"),
    ]

    /// 用时间与正文拼一行 combat 日志。
    static func combat(_ body: String) -> String {
        "[ 2026.01.01 00:00:00 ] (combat) " + body
    }
}
