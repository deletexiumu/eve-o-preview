// SPDX-License-Identifier: GPL-3.0-or-later
//
// 星图数据：解码、按名称找星系、重名、搜索、显示用的安全等级与译名。

use super::*;
use crate::model::AppLanguage;
use crate::static_data::{SolarSystem, SpaceKind, StaticDataError, SystemRecord};

/// 夹具解码后各类数量正确，舰船与分组分开查。
#[test]
fn fixture_counts() {
    let data = data();
    // 版本号原样保留，设置页与诊断信息显示它。
    assert_eq!(data.sde_build, 3_720_952);
    // 14 个星系里含 1 个虫洞星系；舰船与分组放在同一个列表里，先舰船后分组。
    assert_eq!(data.systems.len(), 14);
    assert_eq!(data.ships.iter().filter(|s| s.group_id.is_some()).count(), 10);
    assert_eq!(data.ships.iter().filter(|s| s.group_id.is_none()).count(), 4);
    assert_eq!(data.ship(SABRE).and_then(|s| s.group_id), Some(INTERDICTOR_GROUP));
    assert_eq!(
        data.ship_group(INTERCEPTOR_GROUP).map(|g| g.name.as_str()),
        Some("Interceptor")
    );
    // 分组 ID 不能当舰船 ID 查：两张表分开。
    assert!(data.ship(INTERCEPTOR_GROUP).is_none());
    // 种类只由 ID 决定：31,000,000 以上是虫洞空间。
    assert_eq!(data.system(THERA).map(|s| s.kind), Some(SpaceKind::Wormhole));
    assert_eq!(data.system(JITA).map(|s| s.kind), Some(SpaceKind::Known));
    assert_eq!(data.region_name(THE_FORGE, AppLanguage::Zh), Some("伏尔戈"));
    // 没有俄文译名时回到英文；不存在的星域是 None。
    assert_eq!(data.region_name(HEIMATAR, AppLanguage::Ru), Some("Heimatar"));
    assert_eq!(data.region_name(1, AppLanguage::En), None);
}

/// 邻接表双向建立；没有星门的星系没有邻居。
#[test]
fn neighbors() {
    let data = data();
    // New Caldari 有 3 条星门：邻居按 ID 升序，与 jumps 里的先后无关。
    assert_eq!(data.neighbors(NEW_CALDARI), [URLEN, PERIMETER, ONE_DQ]);
    assert_eq!(data.neighbors(JITA), [PERIMETER]);
    assert!(data.neighbors(ONSOOH).is_empty());
    assert!(data.neighbors(THERA).is_empty());
}

/// format 不认识时是 UnsupportedFormat；没有星系时是 Empty；JSON 坏了或缺字段是 Unreadable。
#[test]
fn errors() {
    // 格式版本比应用新：先读 format 就停，不去解可能已经变了的其余结构。
    let newer = JSON.replacen(r#"{"format":1"#, r#"{"format":2"#, 1);
    assert_eq!(
        EveStaticData::decode(&newer).err(),
        Some(StaticDataError::UnsupportedFormat(2))
    );
    // 结构合法但没有星系：当作数据无效，预警不认任何星系。
    let mut empty = file();
    empty.systems.clear();
    assert_eq!(
        EveStaticData::from_file(empty).err(),
        Some(StaticDataError::Empty)
    );
    assert!(matches!(
        EveStaticData::decode("not json"),
        Err(StaticDataError::Unreadable(_))
    ));
    assert!(matches!(
        // 只有 format、缺其余字段：是 Unreadable，不是 Empty。
        EveStaticData::decode(r#"{"format":1}"#),
        Err(StaticDataError::Unreadable(_))
    ));
    assert!(matches!(
        EveStaticData::decode("{}"),
        Err(StaticDataError::Unreadable(_))
    ));
}

/// system_named 认英文、中文、带 `*`、大小写不同、带首尾空白的写法。
#[test]
fn system_by_name() {
    let data = data();
    let id = |name: &str| data.system_named(name).map(|s| s.id);
    assert_eq!(id("Jita"), Some(JITA));
    assert_eq!(id("吉他"), Some(JITA));
    // 中文客户端在译名后加 `*`，查名称时去掉。
    assert_eq!(id("吉他*"), Some(JITA));
    // 首尾空白与多个 `*` 一起去掉，大小写不论。
    assert_eq!(id("  jITA ** "), Some(JITA));
    assert_eq!(id("hed-gp"), Some(HED_GP));
    assert_eq!(id(""), None);
    // 去掉 `*` 后是空串：不查。
    assert_eq!(id("*"), None);
    assert_eq!(id("Nowhere"), None);
}

/// 日文名相同的 Onsooh 与 Aunsou 取 ID 小的；已知空间与虫洞空间重名时取已知空间。
#[test]
fn duplicate_names() {
    let data = data();
    assert_eq!(data.system_named("オンスー").map(|s| s.id), Some(ONSOOH));
    assert_eq!(data.system_named("Aunsou").map(|s| s.id), Some(AUNSOU));
    let mut file = file();
    let record = |i: i64, n: &str| SystemRecord {
        i,
        n: n.into(),
        l: Some([("zh".to_owned(), "回声".to_owned())].into()),
        s: None,
        r: None,
    };
    // 虫洞星系先加入、ID 也不是最大：仍不能盖掉已知空间的同名星系。
    file.systems.push(record(31_000_001, "Shadow"));
    file.systems.push(record(30_009_999, "Echo"));
    let data = EveStaticData::from_file(file).expect("能建");
    assert_eq!(data.system_named("回声").map(|s| s.id), Some(30_009_999));
}

/// search_systems：完全相同的排最前，其余按名称长度；遵守 limit。
#[test]
fn search() {
    let data = data();
    let names = |data: &EveStaticData, prefix: &str, limit: usize| -> Vec<String> {
        data.search_systems(prefix, limit)
            .iter()
            .map(|s| s.name.clone())
            .collect()
    };
    assert_eq!(names(&data, "naga", 5), ["Naga"]);
    let mut file = file();
    for (i, n) in [(30_009_998, "Jitana"), (30_009_997, "Jit")] {
        file.systems.push(SystemRecord {
            i,
            n: n.into(),
            l: None,
            s: None,
            r: None,
        });
    }
    let extended = EveStaticData::from_file(file).expect("能建");
    // 完全相同的 Jit 在最前，其余按名称长度。
    assert_eq!(names(&extended, "jit", 10), ["Jit", "Jita", "Jitana"]);
    assert_eq!(names(&extended, "JITA", 10), ["Jita", "Jitana"]);
    assert_eq!(names(&extended, "jit", 2).len(), 2);
    // 前缀也匹配译名，返回的仍是星系本身。
    assert_eq!(names(&extended, "吉", 10), ["Jita"]);
    assert!(names(&extended, " ", 10).is_empty());
}

/// 显示用的安全等级：0.034 显示 0.1，0.05 显示 0.1，0.449 显示 0.4，-0.386 显示 -0.4，0.946 显示 0.9。
#[test]
fn display_security() {
    let data = data();
    let shown = |id: i64| data.system(id).and_then(SolarSystem::display_security);
    // 0.034 在游戏里显示 0.1：大于 0 的低安不会显示成 0.0。
    assert_eq!(shown(NAGA_SYSTEM), Some(0.1));
    assert_eq!(shown(ONE_DQ), Some(-0.4));
    assert_eq!(shown(JITA), Some(0.9));
    let with = |security: Option<f64>| {
        let mut system = SolarSystem::new(1, "X");
        system.security = security;
        system.display_security()
    };
    assert_eq!(with(Some(0.05)), Some(0.1));
    assert_eq!(with(Some(0.449)), Some(0.4));
    assert_eq!(with(Some(0.0)), Some(0.0));
    // -0.04 四舍五入得 -0.0，显示时写成 0.0。
    assert!(with(Some(-0.04)).is_some_and(|v| v == 0.0 && v.is_sign_positive()));
    assert_eq!(with(None), None);
}

/// name_in 有译名时取译名，没有时回到英文。
#[test]
fn localized_names() {
    let data = data();
    let jita = data.system(JITA).expect("有 Jita");
    assert_eq!(jita.name_in(AppLanguage::Zh), "吉他");
    // 没有日文译名：回到英文名。
    assert_eq!(jita.name_in(AppLanguage::Ja), "Jita");
    assert_eq!(
        data.system(T5ZI).map(|s| s.name_in(AppLanguage::Zh)),
        Some("T5ZI-S")
    );
    let crow = data.ship(CROW).expect("有 Crow");
    assert_eq!(crow.name_in(AppLanguage::Ko), "크로우");
    assert_eq!(crow.name_in(AppLanguage::De), "Crow");
}

/// 文件结构往返一致：l、s、r 缺失时编码里也省略。
#[test]
fn file_round_trip() {
    let file = file();
    let again: crate::static_data::StaticDataFile =
        serde_json::from_str(&serde_json::to_string(&file).expect("能编码")).expect("能解码");
    assert_eq!(again, file);
    // HED-GP 没有译名：编码时省略 l，文件不会变大。
    let hed = file.systems.iter().find(|s| s.n == "HED-GP").expect("有 HED-GP");
    assert!(!serde_json::to_string(hed).expect("能编码").contains("\"l\""));
}

/// 日志里的错误名只有种类，不含 Unreadable 的说明（说明可能含主目录路径）。
#[test]
fn error_log_names() {
    assert_eq!(
        StaticDataError::Unreadable(r"C:\Users\someone\x.json missing".into()).log_name(),
        "unreadable"
    );
    assert_eq!(
        StaticDataError::UnsupportedFormat(2).log_name(),
        "unsupportedFormat(2)"
    );
    assert_eq!(StaticDataError::Empty.log_name(), "empty");
}

/// 仓库里的真实数据文件能解码，数量在合理范围内（防止生成脚本与解码规则走样）。
#[test]
fn bundled_file_decodes() {
    // 真实数据有 5,000 多个已知空间星系；文件随仓库更新，这里只看大致规模。
    let json = include_str!("../../../../../../shared/static/eve-static.json");
    let data = EveStaticData::decode(json).expect("真实数据能解码");
    assert!(data.systems.len() > 5_000);
    assert!(data.system_named("Jita").is_some());
    assert!(!data.neighbors(JITA).is_empty());
}
