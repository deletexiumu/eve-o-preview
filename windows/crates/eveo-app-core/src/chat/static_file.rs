// SPDX-License-Identifier: GPL-3.0-or-later
//
// 星图数据的来源与读取，对应 macOS 的 BundleStaticDataProvider（docs/macos/design-intel-translate.md 4.4 节）。
// Windows 把 shared/static/eve-static.json 嵌进 exe（架构文档 6.2 节），不必随程序带一个数据文件；
// 外部文件覆盖内置数据的规则与 macOS 相同：
// 1. 环境变量 EVEO_STATIC_DATA 指定的路径（只用于调试）：存在时只用它，无效也不退回别的来源。
// 2. 数据目录（%APPDATA%\EVE-O Preview）下的 eve-static.json（用户手动覆盖）：
//    与内置数据都解码，取 SDE 版本较新的一个，版本相同时取内置的；覆盖文件无效时用内置的。
// 3. 内置数据。
// 读文件与解码要几十毫秒，由应用层放到后台线程；这里只是普通函数，能在 Linux 上测试。
// 诊断信息只写来源的名字（environment、userOverride、embedded），不写路径：路径里有 Windows 用户名。

//! 星图数据的来源与读取。

use std::path::Path;
use std::sync::Arc;

use eveo_core::static_data::EveStaticData;

use super::features::StaticDataLoad;

/// 数据文件的文件名。
pub const FILE_NAME: &str = "eve-static.json";

/// 调试用的环境变量名。
pub const ENVIRONMENT_VARIABLE: &str = "EVEO_STATIC_DATA";

/// 按文件头说明的顺序读星图数据。
/// - environment：环境变量给的路径；没设或为空时为 None。
/// - user_override：数据目录下的覆盖文件（不存在也传，函数自己判断）。
/// - embedded：嵌进 exe 的 JSON 文本；测试里可以传空串表示没有内置数据。
pub fn load(environment: Option<&Path>, user_override: &Path, embedded: &str) -> StaticDataLoad {
    if let Some(path) = environment.filter(|p| p.exists()) {
        return decode_file(path, "environment");
    }
    let builtin = (!embedded.is_empty()).then(|| decode(embedded, "embedded"));
    if !user_override.exists() {
        return builtin.unwrap_or(StaticDataLoad::Missing);
    }
    let overridden = decode_file(user_override, "userOverride");
    match (overridden, builtin) {
        // 两个都有效：取 SDE 版本较新的；相同时用内置的（应用更新后自带的数据至少不比旧的覆盖文件差）。
        (StaticDataLoad::Loaded(user, source), Some(StaticDataLoad::Loaded(built, built_source))) => {
            if built.sde_build >= user.sde_build {
                StaticDataLoad::Loaded(built, built_source)
            } else {
                StaticDataLoad::Loaded(user, source)
            }
        }
        // 覆盖文件有效、内置数据缺失或无效：用覆盖文件。
        (loaded @ StaticDataLoad::Loaded(..), _) => loaded,
        // 覆盖文件无效：退回内置数据；内置数据也没有时报告覆盖文件的结果（无效）。
        (invalid, builtin) => builtin.unwrap_or(invalid),
    }
}

/// 读一个文件并解码；读不了与解不开都算无效。
fn decode_file(path: &Path, source: &'static str) -> StaticDataLoad {
    match std::fs::read_to_string(path) {
        Ok(text) => decode(&text, source),
        Err(_) => StaticDataLoad::Invalid,
    }
}

/// 解码 JSON 文本。
fn decode(text: &str, source: &'static str) -> StaticDataLoad {
    match EveStaticData::decode(text) {
        Ok(data) => StaticDataLoad::Loaded(Arc::new(data), source),
        Err(_) => StaticDataLoad::Invalid,
    }
}

#[cfg(test)]
mod tests {
    //! 来源的优先次序：环境变量独占；覆盖文件与内置数据比版本；无效时退回。

    use std::path::PathBuf;

    use super::*;

    /// 只有一个星系的数据，SDE 版本按参数。
    fn json(build: i64) -> String {
        format!(
            r#"{{"format":1,"sdeBuild":{build},"regions":[],"systems":[{{"i":30000142,"n":"Jita","s":0.946,"r":10000002}}],"jumps":[],"shipGroups":[],"ships":[]}}"#
        )
    }

    /// 用例自己的临时目录（按用例名区分，彼此不冲突）。
    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("eveo-static-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("能建临时目录");
        dir
    }

    /// 结果的来源与版本；不是 Loaded 时给出种类名。
    fn describe(result: &StaticDataLoad) -> String {
        match result {
            StaticDataLoad::Loaded(data, source) => format!("{source}:{}", data.sde_build),
            StaticDataLoad::Missing => "missing".to_owned(),
            StaticDataLoad::Invalid => "invalid".to_owned(),
        }
    }

    /// 没有覆盖文件时用内置数据；连内置数据也没有时是 Missing。
    #[test]
    fn embedded_only() {
        let dir = temp_dir("embedded");
        let absent = dir.join(FILE_NAME);
        assert_eq!(describe(&load(None, &absent, &json(5))), "embedded:5");
        assert_eq!(describe(&load(None, &absent, "")), "missing");
    }

    /// 覆盖文件较新时用它；不比内置的新时用内置的；无效时退回内置的。
    #[test]
    fn user_override_versus_embedded() {
        let dir = temp_dir("override");
        let file = dir.join(FILE_NAME);
        std::fs::write(&file, json(7)).unwrap();
        assert_eq!(describe(&load(None, &file, &json(5))), "userOverride:7");
        assert_eq!(describe(&load(None, &file, &json(7))), "embedded:7");
        std::fs::write(&file, "not json").unwrap();
        assert_eq!(describe(&load(None, &file, &json(5))), "embedded:5");
        assert_eq!(describe(&load(None, &file, "")), "invalid");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 环境变量指定的文件存在时只用它，哪怕它无效；不存在时当作没设。
    #[test]
    fn environment_wins() {
        let dir = temp_dir("environment");
        let debug = dir.join("debug.json");
        let absent = dir.join(FILE_NAME);
        std::fs::write(&debug, json(3)).unwrap();
        assert_eq!(describe(&load(Some(&debug), &absent, &json(9))), "environment:3");
        std::fs::write(&debug, "{}").unwrap();
        assert_eq!(describe(&load(Some(&debug), &absent, &json(9))), "invalid");
        let missing = dir.join("missing.json");
        assert_eq!(describe(&load(Some(&missing), &absent, &json(9))), "embedded:9");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
