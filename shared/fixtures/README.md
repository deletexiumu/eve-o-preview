# 跨平台测试用例

macOS 与 Windows 两份 Core 用同一批用例对齐行为（[架构文档 5.4 节](../../docs/windows/architecture.md)）。
每个用例只有「输入 + 期望输出」的数据，不含任何语言的代码。

| 目录 | 内容 | macOS 的一致性测试 | Windows 的一致性测试 |
| --- | --- | --- | --- |
| [title](title/README.md) | 窗口标题 → 身份与显示标题 | `SharedFixtureTests.swift` | `eveo-core/tests/shared_fixtures.rs` |
| [cycle](cycle/README.md) | 循环组与登录客户端的下一个目标 | 同上 | 同上 |
| [clients](clients/README.md) | 一批候选窗口 → 每个进程的主窗口 | 同上 | 同上 |
| [config](config/README.md) | 配置文件 → 迁移、校验后的配置与改正的字段 | `SharedConfigFixtureTests.swift` | `eveo-core/tests/shared_config.rs` |

规则：

1. 改解析或规则时先改这里的用例与设计文档，再改两端的实现。只改一端时，另一端的一致性测试会失败。
2. 用例里的角色名都是虚构的。
3. 改动 `shared/` 会同时触发 macOS 与 Windows 两个工作流。
4. 期望输出的 JSON 结构写在各目录的 `README.md` 里。
