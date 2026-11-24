// SPDX-License-Identifier: GPL-3.0-or-later
//
// AMD、Intel 限帧规则的用例：选厂商、接手与还原、用户之后自己改过、换了显卡，以及同步报告的编码。

use super::*;

/// 一条记录：在 `target` 上接手前是 `original`，我们写了 `applied`。
fn record(target: &str, original: CapValue, applied: u32) -> ValueRecord {
    ValueRecord {
        target: target.to_owned(),
        original,
        applied_fps: applied,
    }
}

/// 关着、帧数是 `fps` 的值。
fn off(fps: u32) -> CapValue {
    CapValue { enabled: false, fps }
}

/// 选厂商：独显优先，同类时 AMD 优先，都没有时为 None。
#[test]
fn chooses_discrete_first() {
    use GpuKind::{Discrete, Integrated};
    assert_eq!(
        choose_vendor(Some(Integrated), Some(Discrete)),
        Some(Vendor::Intel)
    );
    assert_eq!(choose_vendor(Some(Discrete), Some(Integrated)), Some(Vendor::Amd));
    assert_eq!(choose_vendor(None, Some(Integrated)), Some(Vendor::Intel));
    assert_eq!(
        choose_vendor(Some(Integrated), Some(Integrated)),
        Some(Vendor::Amd)
    );
    assert_eq!(choose_vendor(Some(Integrated), None), Some(Vendor::Amd));
    assert_eq!(choose_vendor(None, None), None);
}

/// 打开再关闭：记下接手前的值（关着、144 帧），关闭时原样写回。
#[test]
fn enable_then_disable_restores_original() {
    let plan = plan_value_enable("gpu1", off(144), None, 60);
    assert_eq!(plan.write, Some(CapValue::on(60)));
    let saved = plan.record.expect("记录");
    assert_eq!(saved, record("gpu1", off(144), 60));

    let back = plan_value_disable("gpu1", CapValue::on(60), Some(&saved));
    assert_eq!(back.write, Some(off(144)));
    assert_eq!(back.record, None);
}

/// 改帧数：沿用记录里接手前的值；驱动里已经是想要的值时不写。
#[test]
fn changing_fps_keeps_original_and_skips_same_value() {
    let first = record("gpu1", off(144), 60);
    let plan = plan_value_enable("gpu1", CapValue::on(60), Some(&first), 45);
    assert_eq!(plan.write, Some(CapValue::on(45)));
    assert_eq!(plan.record, Some(record("gpu1", off(144), 45)));

    let check = plan_value_enable("gpu1", CapValue::on(60), Some(&first), 60);
    assert_eq!(check.write, None);
    assert_eq!(check.record, Some(first));
}

/// 用户之后在显卡软件里改成了 90 或关掉了：关闭时不动驱动，只丢掉记录。
#[test]
fn disable_respects_later_user_change() {
    let saved = record("gpu1", off(144), 60);
    assert_eq!(
        plan_value_disable("gpu1", CapValue::on(90), Some(&saved)).write,
        None
    );
    assert_eq!(plan_value_disable("gpu1", off(60), Some(&saved)).write, None);
}

/// 换了显卡：关闭时不动新显卡；再打开时以新显卡的现状作为接手前的值。
#[test]
fn other_gpu_is_not_touched() {
    let saved = record("old", off(144), 60);
    assert_eq!(
        plan_value_disable("new", CapValue::on(60), Some(&saved)).write,
        None
    );
    let plan = plan_value_enable("new", CapValue::on(75), Some(&saved), 60);
    assert_eq!(plan.record, Some(record("new", CapValue::on(75), 60)));
}

/// 没有记录时关闭什么都不做。
#[test]
fn disable_without_record_does_nothing() {
    let plan = plan_value_disable("gpu1", CapValue::on(60), None);
    assert_eq!(
        plan,
        ValuePlan {
            write: None,
            record: None
        }
    );
}

/// 夹到驱动的范围；范围不合理时原样返回。
#[test]
fn clamps_to_driver_range() {
    assert_eq!(clamp_to_range(10, (30, 300)), 30);
    assert_eq!(clamp_to_range(500, (30, 300)), 300);
    assert_eq!(clamp_to_range(60, (30, 300)), 60);
    assert_eq!(clamp_to_range(60, (300, 30)), 60);
}

/// 记录与同步报告：编码再解码不变；报告取最后一个非空行，内容不对时为 None。
#[test]
fn record_and_report_round_trip() {
    let saved = record("gpu1", off(144), 60);
    assert_eq!(ValueRecord::decode(&saved.encode()), Some(saved));
    assert_eq!(ValueRecord::decode(b"nope"), None);

    let reports = [
        SyncReport {
            vendor: Some(Vendor::Amd),
            result: Ok(Synced {
                steps: 1,
                applied: Some(60),
            }),
        },
        SyncReport {
            vendor: Some(Vendor::Intel),
            result: Err(SyncError::Failed(0x4000_000a)),
        },
        SyncReport {
            vendor: None,
            result: Err(SyncError::Unsupported),
        },
    ];
    for report in reports {
        let text = format!("log line\n{}\n\n", report.encode());
        assert_eq!(SyncReport::decode(&text), Some(report));
    }
    assert_eq!(SyncReport::decode(""), None);
    assert_eq!(SyncReport::decode("{\"vendor\": 1}"), None);
}
