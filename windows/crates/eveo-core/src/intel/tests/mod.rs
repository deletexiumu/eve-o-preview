// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警消息解析的用例，对应 macOS 的 IntelParserTests 与 IntelClearRulesTests。人名都是虚构的；
// 星系与舰船取自星图数据的夹具，与用户的日志无关。

mod clear;
mod feed;
mod parser;
mod pilots;
mod presenter;

use super::IntelReport;
use super::parser::parse_with;
use crate::static_data::EveStaticData;

/// 解析一条消息，并核对各段拼起来等于原文。
pub(super) fn parse(data: &EveStaticData, text: &str) -> IntelReport {
    let report = parse_with(text, data);
    let joined: String = report.segments.iter().map(|s| s.text.as_str()).collect();
    assert_eq!(joined, text, "各段拼起来应与原文相同");
    report
}
