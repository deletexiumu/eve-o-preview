# 热键用例

`cases.json` 分四组。热键字符串的语法两端相同（修饰键在前、`+` 连接、可带 `@global` 或 `@game` 后缀），
但修饰键的叫法与键码各用本平台的：macOS 的规范写法是 `ctrl+opt+shift+cmd+键`，键码是 Carbon 的 `kVK_*`；
Windows 把 `opt` 读成 `alt`、`cmd` 读成 `win`，规范写法是 `ctrl+alt+shift+win+键`，键码是 `VK_*`
（[架构文档 4.4 节、5.5 节](../../../docs/windows/architecture.md)）。

两端结果不同的地方，期望值写成 `{"macos": …, "windows": …}`，各端取自己的那个；其余的期望值两端共用。

| 组 | 输入 | 期望 |
| --- | --- | --- |
| `parse` | `input`：一条热键字符串 | 规范写法；解析失败为 `null`。规范写法要能解析回自己 |
| `plan` | `profile`：配置方案（同配置文件里的写法，缺的键取默认值） | `bindings` 与 `issues`，见下 |
| `mouseMatcher` | `steps`：按顺序执行的步骤，见下 | 每步自带期望 |
| `oneTimeDefaults` | `pending`：`applied` → 待补的项；`apply`：`ids` 与 `profiles` → 每个配置方案补后的 `toggleHideAll`（以及给出时的 `highlightEnabled`、`highlightColor`） | 见左 |

`plan` 的结果：

- 绑定：`{"id": 编号, "hotkey": 规范写法, "action": 动作, "scope": "global" | "game"}`。
- 问题：`{"kind": "unparsable", "text": 原文, "action": 动作}`、
  `{"kind": "duplicate", "hotkey", "kept": 动作, "dropped": 动作}`、
  `{"kind": "rejected", "hotkey", "action", "reason"}`。
  `reason` 是 `missingModifier`、`systemReserved`，或只有 Windows 有的 `unsupportedMouseButton`（只能检测 Mouse3～Mouse5）。
- 动作写成 `toggleHideAll`、`minimizeAll`、`cycleLoginClients`、`cycle:<循环组 id>:forward|backward`、`character:<角色名>`。

两端的系统保留名单不同：macOS 拦截 `cmd` 或 `cmd+shift` 加 Tab、Space、Q、W、H、M、Grave；
Windows 拦截 Alt（可加 Shift）加 Tab、Esc、F4、Space，Ctrl（可加 Shift）加 Esc，含 Win 的 L，以及单独的 F12 或 Shift+F12。

`mouseMatcher` 的步骤（`op`）：

| op | 字段 | 作用 |
| --- | --- | --- |
| `bindings` | `bindings`：`{"id", "hotkey": 鼠标热键, "scope"}` 的数组 | 替换绑定表 |
| `frontmost`、`suspended` | `value` | 前台是不是 EVE、是否暂停 |
| `hookRemoved` | | 监听被系统关掉或拆除（macOS 的 `tapWasDisabled`） |
| `down`、`up`、`dragged` | `hotkey`：事件的按钮与修饰键，`expect`：`pass`、`swallow` 或 `fire:<编号>` | 送一个鼠标事件 |
| `refresh` | `now`，`expect`：下一次检查的时刻或 `null` | 整理「只因按着按钮而开着」的截止时刻 |
| `check` | `shouldListen`、`hasActiveBinding` | 核对监听状态 |
