// SPDX-License-Identifier: GPL-3.0-or-later
//
// UTC 时间与公历日期的换算，以及 ISO 8601 的写法，不依赖时区数据库：
// - 日志一行的时间（毫秒）、state.json 与 session.json 里的时刻（与 macOS 的 JSONEncoder `.iso8601` 相同，精确到秒）。
// - 时刻统一是 1970 年以来的秒数（f64），与 Core 其余地方一致。
// 公历换算用 Howard Hinnant 的 days_from_civil / civil_from_days 算法。

//! UTC 时间与 ISO 8601。

/// 能写出的最晚时刻（9999-12-31T23:59:59Z），再大的值按它写。
const MAX_TIME: f64 = 253_402_300_799.0;

/// 公历日期到 1970-01-01 的天数。
pub fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// 1970-01-01 以来的天数换成公历年月日。
pub fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// 时刻换成毫秒数：早于 1970 年或不是有限数时按 0，晚于 9999 年时按上限。
fn clamp_millis(time: f64) -> i64 {
    if time.is_finite() && time > 0.0 {
        (time.min(MAX_TIME) * 1000.0).round() as i64
    } else {
        0
    }
}

/// 毫秒数写成 `YYYY-MM-DDTHH:MM:SS`，再接上 `tail`（`.789Z` 或 `Z`）。
fn layout(millis_total: i64, with_millis: bool) -> String {
    let seconds_total = millis_total.div_euclid(1000);
    let millis = millis_total.rem_euclid(1000);
    let days = seconds_total.div_euclid(86_400);
    let seconds = seconds_total.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let base = format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}",
        seconds / 3600,
        seconds % 3600 / 60,
        seconds % 60
    );
    if with_millis {
        format!("{base}.{millis:03}Z")
    } else {
        format!("{base}Z")
    }
}

/// 精确到毫秒的 UTC 时间：`2026-11-21T04:05:06.789Z`（日志一行用）。
pub fn iso8601_millis(time: f64) -> String {
    layout(clamp_millis(time), true)
}

/// 精确到秒的 UTC 时间：`2026-11-21T04:05:06Z`（state.json、session.json 用；秒以下截掉，不四舍五入）。
pub fn iso8601_seconds(time: f64) -> String {
    let millis = clamp_millis(time.floor());
    layout(millis, false)
}

/// 解析 ISO 8601 的 UTC 时间：`YYYY-MM-DDTHH:MM:SS`，可带小数秒，结尾是 `Z` 或 `±HH:MM`。
/// 格式不符或数值越界时返回 None。
pub fn parse_iso8601(text: &str) -> Option<f64> {
    let bytes = text.as_bytes();
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || !matches!(bytes[10], b'T' | b't') {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' {
        return None;
    }
    let number = |range: std::ops::Range<usize>| -> Option<i64> {
        let part = text.get(range)?;
        part.bytes()
            .all(|b| b.is_ascii_digit())
            .then(|| part.parse().ok())?
    };
    let (year, month, day) = (number(0..4)?, number(5..7)?, number(8..10)?);
    let (hour, minute, second) = (number(11..13)?, number(14..16)?, number(17..19)?);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    // 小数秒：点后面的数字。
    let mut rest = &text[19..];
    let mut fraction = 0.0;
    if let Some(after) = rest.strip_prefix('.') {
        let digits = after.bytes().take_while(u8::is_ascii_digit).count();
        if digits == 0 {
            return None;
        }
        fraction = format!("0.{}", &after[..digits]).parse().ok()?;
        rest = &after[digits..];
    }
    // 时区：Z 或 ±HH:MM，换算回 UTC。
    let offset = match rest {
        "Z" | "z" => 0,
        _ => {
            let sign = match rest.as_bytes().first()? {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let zone = rest.get(1..)?;
            let (h, m) = zone.split_once(':')?;
            if h.len() != 2 || m.len() != 2 {
                return None;
            }
            sign * (h.parse::<i64>().ok()? * 3600 + m.parse::<i64>().ok()? * 60)
        }
    };
    let days = days_from_civil(year, month, day);
    let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Some(seconds as f64 + fraction)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 写法：毫秒与秒两种；越界的值按 0 或上限。
    #[test]
    fn formats() {
        assert_eq!(iso8601_millis(1_763_697_906.789), "2025-11-21T04:05:06.789Z");
        assert_eq!(iso8601_seconds(1_763_697_906.789), "2025-11-21T04:05:06Z");
        assert_eq!(iso8601_millis(f64::NAN), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601_seconds(1e20), "9999-12-31T23:59:59Z");
        assert_eq!(iso8601_seconds(1_709_164_800.0), "2024-02-29T00:00:00Z");
    }

    /// 解析：与写法往返一致；带小数秒与时区偏移；格式不符时为 None。
    #[test]
    fn parses() {
        assert_eq!(parse_iso8601("2025-11-21T04:05:06Z"), Some(1_763_697_906.0));
        assert_eq!(parse_iso8601("2025-11-21T12:05:06+08:00"), Some(1_763_697_906.0));
        let fractional = parse_iso8601("2025-11-21T04:05:06.5Z").unwrap();
        assert!((fractional - 1_763_697_906.5).abs() < 1e-6);
        for bad in [
            "",
            "2025-11-21",
            "2025-13-01T00:00:00Z",
            "2025-11-21T04:05:06",
            "2025-11-21T04:05:06.Z",
            "abcd-ef-ghTij:kl:mnZ",
        ] {
            assert_eq!(parse_iso8601(bad), None, "{bad}");
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(civil_from_days(days_from_civil(2024, 2, 29)), (2024, 2, 29));
    }
}
