# 循环用例

`cases.json` 有两组：

```json
{
  "group": [
    {
      "name": "用例说明",
      "members": ["A", "B", "C", "D"],
      "direction": "forward",
      "active": "B",
      "running": ["A", "B", "C", "D"],
      "skipped": [],
      "expected": "C"
    }
  ],
  "login": [
    { "name": "用例说明", "pids": [300, 100, 200], "activePID": 100, "direction": "forward", "expected": 200 }
  ]
}
```

- `direction` 是 `forward` 或 `backward`。
- `group`：`active` 为 `null` 表示当前没有激活的成员；`expected` 为 `null` 表示没有可切换的成员。
- `login`：`activePID` 为 `null` 表示前台不是登录客户端；`expected` 为 `null` 表示没有登录客户端。
