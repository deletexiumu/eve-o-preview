# 缩略图规划用例

`cases.json` 的 `cases` 是一个用例数组。每个用例给出一次规划的全部输入，期望只写需要核对的部分。
两端画面的来源不同（macOS 用屏幕捕获，Windows 用 DWM 缩略图），用例里的画面都按正常处理：
macOS 的测试给全部权限、全部窗口的捕获都在出帧；Windows 的测试把全部窗口的缩略图状态设为已注册。

输入：

| 键 | 内容 |
| --- | --- |
| `clients` | `{"id", "pid", "identity": {"kind": "character", "name"} 或 {"kind": "login"} 或 {"kind": "unknown"}, "frame": [x, y, 宽, 高], "isMinimized"?, "isFullScreen"?}` 的数组，顺序即呈现的顺序 |
| `frontmost` | `{"client": pid}`、`"selfApp"` 或 `"other"` |
| `profile` | 配置方案（同配置文件里的写法，缺的键取默认值） |
| `session` | `hideAll`、`skippedCharacters`、`hoveredWindow`、`interactingWindows`、`lastEVEContextAt`、`lastActivePID`、`combatAlerts`（窗口编号 → `{"startedAt", "until"}`），缺的键取默认值 |
| `screens` | 同 [layout](../layout/README.md) 的写法 |
| `now` | 当前时刻（秒） |

期望（`expect`）：

| 键 | 内容 |
| --- | --- |
| `presentations` | 每个客户端一个对象，只比较写出的字段：`frame`、`isVisible`、`title`、`showsTitle`、`titleFontSize`、`titleColor`、`opacity`、`highlightColor`、`highlightThickness`、`borderColor`、`borderThickness`、`alert`（`{"color", "style"}` 或 `null`）、`isActive`、`isSkipped`、`isAlwaysOnTop`、`isOverFullScreen`、`isZoomed`、`placeholder`（`none` 或 `minimized`） |
| `layoutsToPersist` | 要写回的自动布局（可省略） |
| `visible` | 可见的窗口编号，按客户端顺序：macOS 是要捕获的窗口，Windows 是要保持注册的 DWM 缩略图（可省略） |
| `nextWakeAt` | 下一次定时重算的时刻或 `null`（可省略） |

占位、捕获规格与画面裁剪只在各自的平台有意义，不在这里比较。
