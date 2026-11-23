// SPDX-License-Identifier: GPL-3.0-or-later
//
// 配置结构的声明宏。macOS 的每个配置结构都手写 init(from:)，规则是：
// - 键缺失或值为 null 时取该字段的默认值（decodeIfPresent），多余的键忽略；
// - 值的类型不对时整个文件判为损坏（宽松解码的枚举除外）；
// - 编码时可选字段为 nil 就不写这个键。
// serde 的 `#[serde(default)]` 遇到 null 会报错，与第一条不符，所以这里为每个结构生成一个
// 「全部字段都是 Option」的影子结构，经它读写，再按默认值补齐。

/// 声明一个配置结构及其影子结构、默认值与读写规则。
///
/// 每个字段写成 `种类 名字: 类型 = 默认值, "JSON 键名";`，种类有四种：
/// - `req`：缺失或 null 时取默认值；
/// - `opt`：字段类型是 `Option<类型>`，缺失或 null 时为 `None`，为 `None` 时不写这个键（默认值写 `None`）；
/// - `lenient`：字符串枚举，类型不对或取值不认识时都取默认值；
/// - `strict`：字符串枚举，不是字符串时判为损坏，取值不认识时取默认值。
macro_rules! config_struct {
    (
        $(#[$meta:meta])*
        pub struct $name:ident via $raw:ident {
            $(
                $(#[$fmeta:meta])*
                $kind:ident $field:ident : $ty:ty = $default:expr, $key:literal;
            )*
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq)]
        pub struct $name {
            $(
                $(#[$fmeta])*
                pub $field: config_field_type!($kind, $ty),
            )*
        }

        impl Default for $name {
            fn default() -> Self {
                Self { $($field: $default,)* }
            }
        }

        #[doc(hidden)]
        #[derive(serde::Serialize, serde::Deserialize)]
        pub struct $raw {
            $(
                #[serde(rename = $key, default, skip_serializing_if = "Option::is_none")]
                $field: config_raw_type!($kind, $ty),
            )*
        }

        impl From<$raw> for $name {
            fn from(raw: $raw) -> Self {
                let defaults = Self::default();
                Self { $($field: config_from_raw!($kind, raw.$field, defaults.$field),)* }
            }
        }

        impl From<$name> for $raw {
            fn from(value: $name) -> Self {
                Self { $($field: config_to_raw!($kind, value.$field),)* }
            }
        }

        impl serde::Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serde::Serialize::serialize(&$raw::from(self.clone()), serializer)
            }
        }

        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                <$raw as serde::Deserialize>::deserialize(deserializer).map(Self::from)
            }
        }
    };
}

/// 字段在配置结构里的类型。
macro_rules! config_field_type {
    (opt, $ty:ty) => { Option<$ty> };
    ($kind:ident, $ty:ty) => { $ty };
}

/// 字段在影子结构里的类型：全部是 `Option`，枚举按种类包一层容错。
macro_rules! config_raw_type {
    (lenient, $ty:ty) => { Option<$crate::support::Lenient<$ty>> };
    (strict, $ty:ty) => { Option<$crate::support::Strict<$ty>> };
    ($kind:ident, $ty:ty) => { Option<$ty> };
}

/// 由影子结构的字段得出配置结构的字段：缺失、null 与不认识的枚举值取默认值。
macro_rules! config_from_raw {
    (opt, $value:expr, $default:expr) => {
        $value
    };
    (req, $value:expr, $default:expr) => {
        $value.unwrap_or($default)
    };
    ($kind:ident, $value:expr, $default:expr) => {
        $value.and_then(|v| v.0).unwrap_or($default)
    };
}

/// 由配置结构的字段得出影子结构的字段，用于编码。
macro_rules! config_to_raw {
    (opt, $value:expr) => {
        $value
    };
    (req, $value:expr) => {
        Some($value)
    };
    (lenient, $value:expr) => {
        Some($crate::support::Lenient(Some($value)))
    };
    (strict, $value:expr) => {
        Some($crate::support::Strict(Some($value)))
    };
}
