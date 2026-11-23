# EVE-O Preview for Windows（开发中）

Windows 原生版，方案见 [架构文档](../docs/windows/architecture.md)。现在处于 M2：把 macOS 的纯逻辑 Core 移植成 Rust。

| crate | 对应 macOS | 状态 |
| --- | --- | --- |
| `crates/eveo-core` | `EVEOPreviewCore` | 几何、客户端模型、标题解析、主窗口挑选、客户端登记、循环（M2a）；配置模型、迁移、校验、配置方案增删改（M2b）；布局与吸附、热键解析与规划、鼠标热键匹配、一次性默认值（M2c）；缩略图规划与可见性（M2d） |

## 本地检查

在 `windows/` 目录运行，Linux、macOS、Windows 都可以：

```sh
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test
# 对 Windows 目标做类型检查（先 rustup target add x86_64-pc-windows-msvc）
cargo check --workspace --all-targets --target x86_64-pc-windows-msvc
```

`cargo test` 包含读取 [`shared/fixtures`](../shared/fixtures/README.md) 的一致性测试，与 macOS 端的 `SharedFixtureTests.swift` 用同一批用例。
