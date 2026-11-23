# EVE-O Preview for Windows（开发中）

Windows 原生版，方案见 [架构文档](../docs/windows/architecture.md)。M2 已把 macOS 的纯逻辑 Core 移植成 Rust；现在处于 M3：Windows 平台层与集成探针。

| crate | 对应 macOS | 状态 |
| --- | --- | --- |
| `crates/eveo-core` | `EVEOPreviewCore` | 几何、客户端模型、标题解析、主窗口挑选、客户端登记、循环（M2a）；配置模型、迁移、校验、配置方案增删改（M2b）；布局与吸附、热键解析与规划、鼠标热键匹配、一次性默认值（M2c）；缩略图规划与可见性（M2d） |
| `crates/eveo-platform-win` | `EVEOPreviewPlatform` | 窗口发现、显示器与 DPI、窗口事件与前台、激活（升级步骤）、键盘热键、鼠标中键与侧键热键（低级鼠标钩子线程）、DWM 缩略图窗口、截图（M3） |
| `crates/eveo-fake-client` | — | 集成测试用的假客户端窗口，CI 复制成 `exefile.exe` 再启动（M3） |
| `crates/eveo-ui` | App 的 Settings、Overlays | Slint 界面（fluent 样式）：设置窗口的视觉原型；`eveo-ui-shot` 用软件渲染器把界面画成 PNG，不需要显示器（M4） |
| `crates/eveo-probe` | `EVEOProbe` | `ci`：CI 上的集成探针（含 Slint 事件循环与原生窗口、热键、钩子的共存检查）；`report`：在真实客户端上收集待实测的事实；`list`：列出顶层窗口（M3） |

## 本地检查

在 `windows/` 目录运行，Linux、macOS、Windows 都可以：

```sh
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test
# 平台层只在 Windows 上有内容，对 Windows 目标做类型检查与 clippy（先 rustup target add x86_64-pc-windows-msvc）
cargo clippy --workspace --all-targets --target x86_64-pc-windows-msvc -- -D warnings
```

在任何系统上给设置窗口截图（明暗两套、首屏与整页；Linux 上没有 Segoe UI，用 `--font Inter` 之类的近似字体）：

```sh
cargo run -p eveo-ui --bin eveo-ui-shot -- --out shots --scale 1.5
```

在 Windows 上跑集成探针（与 CI 的 build 任务相同）：

```powershell
cargo build --workspace
New-Item -ItemType Directory -Force fake, probe-out | Out-Null
Copy-Item target/debug/eveo-fake-client.exe fake/exefile.exe
./target/debug/eveo-probe.exe ci --fake-client fake/exefile.exe --out probe-out
```

在装了 EVE 客户端的机器上收集事实（W1、W3、W5、W8），先登录几个客户端再运行：

```powershell
./target/debug/eveo-probe.exe report --out eve-facts.json --redact --activate
```

`cargo test` 包含读取 [`shared/fixtures`](../shared/fixtures/README.md) 的一致性测试，与 macOS 端的 `SharedFixtureTests.swift` 用同一批用例。
