// SPDX-License-Identifier: GPL-3.0-or-later
//
// 星图数据的用例，对应 macOS 的 StaticDataTests、TermMatcherTests、JumpGraphTests 与 StaticDataFixtures。
// 夹具是一小份星图数据，名称、ID 与安全等级取自 SDE 3720952；星门连接是编的，与游戏的星图无关：
// - 一条链：Jita（吉他）— Perimeter — New Caldari — Urlen — Hek — Amarr。
// - 一条支线：New Caldari — 1DQ1-A — T5ZI-S — HED-GP，这 3 个星系没有译名。
// - 另一个连通块：Naga（纳伽，0.034）— EC-P8R。Naga 与舰船同名。
// - 没有星门的 Onsooh 与 Aunsou，日文名都是 オンスー。
// - 虫洞星系 Thera（席拉）。
// - 星域 The Forge（伏尔戈）与 Heimatar。
// - 舰船分组 Frigate、Interdictor、Interceptor、Logistics；10 艘舰船，Naga、Crow、Stabber 另带日文与韩文名称。

mod data;
mod jumps;
mod matcher;

use super::{EveStaticData, StaticDataFile};

/// 星系 ID。
pub(crate) const JITA: i64 = 30_000_142;
pub(crate) const PERIMETER: i64 = 30_000_144;
pub(crate) const NEW_CALDARI: i64 = 30_000_145;
pub(crate) const URLEN: i64 = 30_000_139;
pub(crate) const HEK: i64 = 30_002_053;
pub(crate) const AMARR: i64 = 30_002_187;
pub(crate) const ONE_DQ: i64 = 30_004_759;
pub(crate) const T5ZI: i64 = 30_004_735;
pub(crate) const HED_GP: i64 = 30_001_161;
pub(crate) const NAGA_SYSTEM: i64 = 30_004_300;
pub(crate) const ONSOOH: i64 = 30_000_013;
pub(crate) const AUNSOU: i64 = 30_003_801;
pub(crate) const THERA: i64 = 31_000_005;

/// 星域 ID。
pub(crate) const THE_FORGE: i64 = 10_000_002;
pub(crate) const HEIMATAR: i64 = 10_000_030;

/// 舰船分组 ID。
pub(crate) const INTERDICTOR_GROUP: i64 = 541;
pub(crate) const INTERCEPTOR_GROUP: i64 = 831;
pub(crate) const LOGISTICS_GROUP: i64 = 832;

/// 舰船类型 ID。
pub(crate) const NAGA_SHIP: i64 = 4_306;
pub(crate) const NAGA_NAVY_ISSUE: i64 = 95_630;
pub(crate) const SABRE: i64 = 22_456;
pub(crate) const CROW: i64 = 11_176;
pub(crate) const MACHARIEL: i64 = 17_738;
pub(crate) const RIFTER: i64 = 587;
pub(crate) const VEXOR_NAVY_ISSUE: i64 = 17_843;

/// 数据文件的 JSON 文本，格式与 shared/static/eve-static.json 相同。
pub(crate) const JSON: &str = r#"{"format":1,"sdeBuild":3720952,"sdeReleaseDate":"2026-11-19T11:07:08Z",
"regions":[{"i":10000002,"n":"The Forge","l":{"zh":"伏尔戈"}},{"i":10000030,"n":"Heimatar","l":{"zh":"西玛特尔"}}],
"systems":[
{"i":30000013,"n":"Onsooh","l":{"ja":"オンスー"},"s":0.443,"r":10000001},
{"i":30000139,"n":"Urlen","l":{"zh":"乌尔仑"},"s":0.949,"r":10000002},
{"i":30000142,"n":"Jita","l":{"zh":"吉他"},"s":0.946,"r":10000002},
{"i":30000144,"n":"Perimeter","l":{"zh":"皮尔米特"},"s":0.949,"r":10000002},
{"i":30000145,"n":"New Caldari","l":{"zh":"新加达里"},"s":0.949,"r":10000002},
{"i":30001161,"n":"HED-GP","s":-0.146,"r":10000014},
{"i":30001984,"n":"EC-P8R","s":-0.447,"r":10000023},
{"i":30002053,"n":"Hek","l":{"zh":"赫克"},"s":0.8,"r":10000042},
{"i":30002187,"n":"Amarr","l":{"zh":"艾玛"},"s":0.949,"r":10000043},
{"i":30003801,"n":"Aunsou","l":{"ja":"オンスー"},"s":0.183,"r":10000048},
{"i":30004300,"n":"Naga","l":{"zh":"纳伽"},"s":0.034,"r":10000054},
{"i":30004735,"n":"T5ZI-S","s":-0.143,"r":10000060},
{"i":30004759,"n":"1DQ1-A","s":-0.386,"r":10000060},
{"i":31000005,"n":"Thera","l":{"zh":"席拉"},"s":-0.99,"r":11000031}],
"jumps":[[30000139,30000145],[30000139,30002053],[30000142,30000144],[30000144,30000145],
[30000145,30004759],[30001161,30004735],[30001984,30004300],[30002053,30002187],[30004735,30004759]],
"shipGroups":[{"i":25,"n":"Frigate","l":{"zh":"护卫舰"}},{"i":541,"n":"Interdictor","l":{"zh":"拦截舰"}},
{"i":831,"n":"Interceptor","l":{"zh":"截击舰"}},{"i":832,"n":"Logistics","l":{"zh":"后勤舰"}}],
"ships":[
{"i":587,"g":25,"n":"Rifter","l":{"zh":"裂谷级"}},
{"i":622,"g":26,"n":"Stabber","l":{"zh":"刺客级","ja":"スタッバー","ko":"스태버"}},
{"i":4306,"g":1201,"n":"Naga","l":{"zh":"娜迦级","ja":"ナーガ","ko":"나가"}},
{"i":11176,"g":831,"n":"Crow","l":{"zh":"黑鸦级","ja":"クロウ","ko":"크로우"}},
{"i":11963,"g":833,"n":"Rapier","l":{"zh":"长剑级"}},
{"i":17738,"g":27,"n":"Machariel","l":{"zh":"马克瑞级"}},
{"i":17843,"g":26,"n":"Vexor Navy Issue","l":{"zh":"狂怒者级海军型"}},
{"i":22456,"g":541,"n":"Sabre","l":{"zh":"剑齿虎级"}},
{"i":22466,"g":540,"n":"Astarte","l":{"zh":"阿施塔特级"}},
{"i":95630,"g":1201,"n":"Naga Navy Issue","l":{"zh":"娜迦级海军型"}}]}"#;

/// 解码出的文件结构。
pub(crate) fn file() -> StaticDataFile {
    serde_json::from_str(JSON).expect("夹具是合法的 JSON")
}

/// 解码出的星图数据。夹具是合法的，解码失败说明解码规则坏了。
pub(crate) fn data() -> EveStaticData {
    EveStaticData::decode(JSON).expect("夹具能解码")
}
