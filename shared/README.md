# shared

macOS 版与 Windows 版共用的数据与工具。目录规划见 [Windows 版架构方案](../docs/windows/architecture.md) 5.1 节。

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| `static/` | 星图与物品数据 `eve-static.json`，以及从 CCP 的 SDE 生成它的 `build-sde-data.py` | 已移入（M1） |
| `l10n/` | 8 种语言的界面文案（TOML），生成 Swift 与 Rust 代码 | M5 |
| `lexicon/` | 情报用语、舰船缩写等词表 | 随 Windows 版的预警功能加入 |
| `providers/` | 翻译服务预设与提示词模板 | 随 Windows 版的翻译功能加入 |
| `schema/` | `config.json`、`state.json` 的 JSON Schema | M2 |
| [`fixtures/`](fixtures/README.md) | 两端共用的测试用例，各自的一致性测试逐个核对 | 标题、循环、主窗口挑选已加入（M2a），其余随 M2 加入 |
| `tools/` | 生成脚本，只用 Python 3 标准库 | 随 `l10n/` 加入 |

改这里的文件会同时触发两个平台的 CI（`.github/workflows/macos.yml` 与 `windows.yml`）。

重新生成星图数据：在仓库根目录运行 `python3 shared/static/build-sde-data.py`，`--check` 只比较 SDE 版本。macOS 的打包脚本 `macos/scripts/build-app.sh` 把它复制进应用包。
