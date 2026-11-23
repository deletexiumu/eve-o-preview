# 配置用例

`cases.json` 的每个用例走一遍「解码 → 迁移 → 校验 → 编码」，与期望比较：

```json
{
  "cases": [
    {
      "name": "用例说明",
      "input": { "schemaVersion": 0, "profiles": [] },
      "expected": {
        "outcome": "ok",
        "migratedFrom": 0,
        "clamped": ["profiles", "activeProfileID"],
        "match": "subset",
        "config": { "schemaVersion": 1 }
      }
    }
  ]
}
```

- 输入写在 `input`（JSON 值）或 `inputText`（原始文字，用于不合法的 JSON 与超出范围的数字）。
- `expected.outcome`：
  - `ok`：读入成功。`migratedFrom` 是迁移前的版本，没有迁移时为 `null`；`clamped` 是校验改正的字段路径，顺序有意义；
    `config` 是校验后再编码出的配置。
  - `newerSchema`：文件来自更新的版本，`found` 是文件里的版本（超出整数范围时是 9223372036854775807）。
  - `corrupt`：文件损坏，应用会隔离它并用默认配置继续。
- `match` 为 `exact` 时对象的键必须完全相同（第一个用例用它固定全部键名与默认值）；为 `subset` 时只比较期望里出现的键。
- 期望里的特殊值：`"<uuid>"` 匹配任意大写 UUID（校验新生成的 id），`"<absent>"` 表示这个键不应写出。
- 数字按数值比较，`384` 与 `384.0` 相同。
- 两端还会检查：校验后的配置再校验一次，`clamped` 为空。
