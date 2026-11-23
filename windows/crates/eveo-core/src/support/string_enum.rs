// SPDX-License-Identifier: GPL-3.0-or-later
//
// 以字符串为原始值的枚举，以及配置解码时对这类枚举的两种容错方式（对应 macOS 的 LenientDecoding）。
// - `Lenient<T>`：键的值类型不对或取值不认识时都退回默认值，不把整个文件判为损坏。
//   以后的版本新增取值时，旧版本读到新值也能继续用。
// - `Strict<T>`：值必须是字符串，否则判为损坏；字符串不认识时退回默认值。macOS 的 zoomAnchor 是这样解码的。

use std::fmt;
use std::marker::PhantomData;

use serde::de::{self, IgnoredAny, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// 以字符串为原始值的枚举，原始值就是写进配置文件的文字。
pub trait StringEnum: Sized + Copy + 'static {
    /// 全部取值，按声明顺序。
    const ALL: &'static [Self];

    /// 写进配置文件的原始值。
    fn raw(self) -> &'static str;

    /// 由原始值找取值，区分大小写；不认识时返回 `None`。
    fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.iter().copied().find(|v| v.raw() == raw)
    }
}

/// 声明一个以字符串为原始值的枚举，实现 [`StringEnum`] 与按原始值的序列化。
///
/// 反序列化只接受认识的原始值；配置里要容错的键用 [`Lenient`] 或 [`Strict`] 包一层。
macro_rules! string_enum {
    (
        $(#[$meta:meta])*
        pub enum $name:ident {
            $(
                $(#[$vmeta:meta])*
                $variant:ident => $raw:literal,
            )+
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum $name {
            $(
                $(#[$vmeta])*
                $variant,
            )+
        }

        impl $crate::support::StringEnum for $name {
            const ALL: &'static [Self] = &[$($name::$variant),+];

            fn raw(self) -> &'static str {
                match self {
                    $($name::$variant => $raw,)+
                }
            }
        }

        impl serde::Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str($crate::support::StringEnum::raw(*self))
            }
        }

        impl<'de> serde::Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let raw = String::deserialize(deserializer)?;
                <$name as $crate::support::StringEnum>::from_raw(&raw).ok_or_else(|| {
                    serde::de::Error::unknown_variant(&raw, &[$($raw),+])
                })
            }
        }
    };
}

/// 宽松解码的枚举值：任何 JSON 值都能读入，不是认识的字符串时为 `None`。
///
/// 序列化时写出原始值（`None` 不会出现在写出的路径上，配置结构总是先换成具体的值）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Lenient<T>(pub Option<T>);

impl<T: StringEnum> Serialize for Lenient<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Some(value) => serializer.serialize_str(value.raw()),
            None => serializer.serialize_none(),
        }
    }
}

impl<'de, T: StringEnum> Deserialize<'de> for Lenient<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(LenientVisitor(PhantomData))
    }
}

/// 接受任何 JSON 值的访问器：字符串按原始值查找，其他类型一律视为不认识。
struct LenientVisitor<T>(PhantomData<T>);

impl<'de, T: StringEnum> Visitor<'de> for LenientVisitor<T> {
    type Value = Lenient<T>;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("任意 JSON 值")
    }

    fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
        Ok(Lenient(T::from_raw(v)))
    }

    fn visit_bool<E: de::Error>(self, _: bool) -> Result<Self::Value, E> {
        Ok(Lenient(None))
    }

    fn visit_i64<E: de::Error>(self, _: i64) -> Result<Self::Value, E> {
        Ok(Lenient(None))
    }

    fn visit_u64<E: de::Error>(self, _: u64) -> Result<Self::Value, E> {
        Ok(Lenient(None))
    }

    fn visit_f64<E: de::Error>(self, _: f64) -> Result<Self::Value, E> {
        Ok(Lenient(None))
    }

    fn visit_unit<E: de::Error>(self) -> Result<Self::Value, E> {
        Ok(Lenient(None))
    }

    fn visit_none<E: de::Error>(self) -> Result<Self::Value, E> {
        Ok(Lenient(None))
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
        // 数组与对象要读完才能继续解析后面的键，内容直接丢弃。
        while seq.next_element::<IgnoredAny>()?.is_some() {}
        Ok(Lenient(None))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {}
        Ok(Lenient(None))
    }
}

/// 只接受字符串的枚举值：不是字符串时报错，字符串不认识时为 `None`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Strict<T>(pub Option<T>);

impl<T: StringEnum> Serialize for Strict<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        Lenient(self.0).serialize(serializer)
    }
}

impl<'de, T: StringEnum> Deserialize<'de> for Strict<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Ok(Strict(T::from_raw(&raw)))
    }
}
