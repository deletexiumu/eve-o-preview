# 窗口标题用例

`cases.json` 的结构：

```json
{
  "cases": [
    {
      "name": "用例说明",
      "title": "EVE - Pilot Alpha",
      "pid": 4101,
      "expected": { "kind": "character", "name": "Pilot Alpha", "displayTitle": "Pilot Alpha" }
    }
  ]
}
```

- `title` 为 `null` 表示平台层读不到标题。
- `expected.kind` 是 `character`、`login` 或 `unknown`；只有 `character` 带 `name`。
- `expected.displayTitle` 是缩略图上显示的标题，未知客户端是 `EVE (<pid>)`。
