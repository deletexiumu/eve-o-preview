# 主窗口挑选用例

`main-windows.json` 的结构：

```json
{
  "cases": [
    {
      "name": "用例说明",
      "windows": [
        { "id": 9002, "pid": 4101, "title": "EVE - Pilot Alpha", "x": 0, "y": 33, "width": 1728, "height": 1018 }
      ],
      "expected": [9002]
    }
  ]
}
```

- `windows` 是平台层预筛后的候选窗口，`title` 为 `null` 表示读不到标题。
- `expected` 是选出的主窗口 ID，按 PID 升序。
- E6 那组窗口按 macOS 上实测的形态构造（每个进程 1 个主窗口，另有细长条与方形的辅助窗口）。
