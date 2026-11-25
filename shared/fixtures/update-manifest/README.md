# 更新清单用例

两端的清单解析与验签（[格式说明](../../../docs/update-manifest.md)）用同一份样例核对。文件由
`make_fixture.py` 生成（调用 `scripts/build_update_manifest.py` 与 openssl），改了清单格式或生成脚本后重新运行它并提交结果。

- `manifest.json`：一份有效的清单（签名信封原文），用下面的测试私钥签名。样例里 1.4.3 只改 macOS、1.4.2 只改 Windows，
  1.4.1 与 1.4.0 两端都改，所以 `latest.macos` 是 1.4.3、`latest.windows` 是 1.4.2。地址是 R2（`dl.example.com`）在前、GitHub 在后。
- `cases.json`：

```json
{
  "publicKey": "测试公钥的十六进制（私钥种子是固定字符串的 SHA-256，只用于用例）",
  "sequence": 1700000000,
  "latest": {"macos": {"version": "1.4.3", "tag": "v1.4.3", "pageURL": "…", "files": [{"name": "…", "size": 1, "sha256": "…", "urls": ["…"]}]}},
  "intermediate": [{"platform": "macos", "running": "1.4.0", "versions": ["1.4.1"]}],
  "invalid": [{"name": "拒收的原因", "envelope": "信封原文"}]
}
```

- `latest`：用正式地址的规则、测试公钥打开 `manifest.json` 后，各平台的发布信息应与它相同（第一个地址是下载地址，其余是后备）。
- `intermediate`：在该平台的发布列表里，按 `running` 挑出的中间版本，新版在前。
- `invalid`：每一份都应被拒收（验签失败或格式不对）。

测试：macOS `UpdateManifestTests.swift`，Windows `eveo-core/src/update/manifest_tests.rs`。
