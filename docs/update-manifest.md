# 更新清单与分发（1.5.0 起）

1.5.0 起，macOS 与 Windows 的更新检查不再读 GitHub 的 Release 接口，改读一份签过名的更新清单 `update-manifest.json`。
清单解决两件事：

1. **按平台提示**：两个平台共用一个版本号（[架构文档 7.4.1 节](windows/architecture.md)），但一个版本可能只改了一个平台。
   例如 1.4.1 只修了 Windows，1.4.0 的 macOS 客户端却也提示更新。清单给每个平台单独写出「改动了本平台的最新版本」，
   只改了别的平台的版本不再提示；跳过的版本里，只有改动了本平台的才列出说明，说明里也只显示本平台的小节。
2. **CDN 分发**：清单与安装包放在 Cloudflare R2（经 Cloudflare 的 CDN 全球分发），GitHub 作为后备。
   清单带 ed25519 签名，每个文件的 SHA-256 写在清单里，所以文件从哪个源取都一样可信，源本身不需要被信任。

## 1 发布说明里的平台标记

`docs/release-notes/v<版本>.md` 的第一行写这个版本改动了哪些平台：

```markdown
<!-- platforms: macos windows -->
```

- 取值是 `macos`、`windows` 中的一个或两个，空格分隔，不重复。
- `scripts/check_release_notes.py` 核对：顶层的 `v*.md` 必须有且只有一个标记，并且在第一行；标记里没有的平台，
  任何语言块里都不能有以这个平台名为标题的小节（`## macOS`、`### Windows` 这类）。
- 1.4.0 标 `macos windows`，1.4.1 标 `windows`。
- 两端都改了的内容写在平台小节之前，标题不要正好是平台名（如「macOS 与 Windows」），这样两端都会显示。

## 2 清单的格式

### 2.1 外层（签名信封）

```json
{"format": 1, "payload": "<清单正文 UTF-8 字节的 base64>", "signature": "<ed25519 签名的 base64>"}
```

- 签名的消息是固定前缀 `eveo-update-manifest-v1\n`（ASCII，含换行）接上 `payload` 解码后的原始字节。
  前缀把清单的签名与 `SHA256SUMS.txt.sig` 区分开，同一把私钥签的两种文件不能互相冒充。
- 签的是原始字节，所以不用规定 JSON 的规范化写法；正文与签名在一个文件里，CDN 缓存不会让两者错开。
- 公钥与 `SHA256SUMS.txt.sig` 相同：`windows/packaging/update-public-key.txt`。Windows 构建时编进 exe；
  macOS 写在 `UpdateSigning.productionPublicKey`，用例核对它与这个文件相同。
- 整个文件最多 1 MiB，生成时控制在 512 KiB 以内（第 2.3 节）。`format` 不是 1、签名不对、正文解析不了时，
  这个源按失败处理，换下一个源。

### 2.2 正文

```json
{
  "schema": 1,
  "sequence": 1795574400,
  "generatedAt": "2026-11-25T03:00:00Z",
  "latest": {
    "macos": {
      "version": "1.5.0",
      "tag": "v1.5.0",
      "pageURL": "https://github.com/deletexiumu/eve-o-preview/releases/tag/v1.5.0",
      "files": [
        {"name": "EVE-O-Preview-1.5.0.dmg", "size": 12345678, "sha256": "…",
         "urls": ["https://eveo.deepai.wiki/v1.5.0/EVE-O-Preview-1.5.0.dmg",
                  "https://github.com/deletexiumu/eve-o-preview/releases/download/v1.5.0/EVE-O-Preview-1.5.0.dmg"]},
        {"name": "SHA256SUMS.txt", "size": 600, "sha256": "…", "urls": ["…", "…"]},
        {"name": "SHA256SUMS.txt.sig", "size": 89, "sha256": "…", "urls": ["…", "…"]}
      ]
    },
    "windows": { "…同上，files 里是 Windows zip、SHA256SUMS.txt、SHA256SUMS.txt.sig…" }
  },
  "releases": [
    {"version": "1.5.0", "platforms": ["macos", "windows"], "notes": "<docs/release-notes/v1.5.0.md 的原文>"},
    {"version": "1.4.1", "platforms": ["windows"], "notes": "…"},
    {"version": "1.4.0", "platforms": ["macos", "windows"], "notes": "…"}
  ]
}
```

- `sequence`：生成时刻的 Unix 秒数，每份清单严格递增，用来拒绝旧清单（第 4 节第 2 条）。
- `latest.<平台>`：标记里含这个平台的最高正式版。每次发布都按仓库里的发布说明重新算出，不沿用上一份清单：
  最新版本没改这个平台时，`latest` 指向更早那个版本的文件（GitHub 与 R2 上都保留旧版本）。
- `files`：应用要下载的文件，`size` 与 `sha256`（小写十六进制）都必须有。`urls` 按优先顺序排列，R2 在前、GitHub 在后；
  没有配置 R2 时只有 GitHub。
- `releases`：1.4.0 起两个平台共用 tag 的各个正式版，新版在前，最多 20 个。`notes` 是发布说明原文（含平台标记与各语言块）。
- 预发布版本（版本号带 `-`）不写进清单，也不上传 R2。Windows 原来「正在运行预发布版时也提示预发布版」的渠道随之结束：
  1.4.0 起两个平台只发正式版，预发布构建（CI 构建）也只收到正式版的提示。

### 2.3 兼容与上限

- 应用忽略不认识的字段，加字段不用改 `schema`。要做不兼容的改动时换一个新文件名，旧文件名继续按 `schema: 1` 发布，
  直到旧版本的用户基本都更新了。
- 生成时整个信封超过 512 KiB，就从最旧的版本开始去掉 `releases` 的项，直到不超过为止；`latest` 指向的版本不去掉。

## 3 清单放在哪里

| 源 | 地址 | 说明 |
| --- | --- | --- |
| R2（经 Cloudflare CDN） | `https://eveo.deepai.wiki/update-manifest.json` | `Cache-Control: max-age=300` |
| GitHub | `https://github.com/deletexiumu/eve-o-preview/releases/latest/download/update-manifest.json` | 清单也作为附件放进每个 Release；`latest` 总是最新的 Release，它的清单覆盖两个平台 |

R2 里的布局：`update-manifest.json` 在根目录，各版本的文件在 `v<版本>/` 下，只写一次（已存在就不覆盖），
`Cache-Control: public, max-age=31536000, immutable`，旧版本不删。

## 4 应用怎么检查

1. 按顺序试清单的源（内置的 R2 地址，然后是 GitHub）。每个源：请求不走本地缓存，超时 15 秒，重定向只跟到 https，
   正文不超过 1 MiB，验签，解析。失败就换下一个源；都失败时按最后一个源的错误处理（与以前的网络错误一样，自动检查时不打扰）。
2. 防回退：正式地址下，state.json 记下接受过的最大 `sequence`。拿到的清单 `sequence` 比它小时，按这个源失败处理，换下一个源。
   测试地址不读也不写这个值。
3. 取 `latest.<本平台>`，交给原来的规则（版本比正在运行的新、没有被跳过）决定提示与否。不再用 ETag；
   升级到 1.5.0 后第一次检查时清掉 state.json 里旧的 `etag` 与 `rateLimitedUntil`。
4. 发布信息：版本、tag、发布页取自 `latest.<本平台>`；标题是 `EVE-O Preview <版本>`；说明取 `releases` 里同一版本的 `notes`。
   每个附件的地址取 `urls` 的第一个，其余的作为后备：下载失败（网络错误、状态码不对、超过声明的大小、哈希不符）时依次换下一个。
   下载的文件都要与清单里的 `sha256` 相符。
5. 中间版本的说明：`releases` 里平台含本平台、且「正在运行的版本 < v < 提示的版本」的各项，规则与以前相同（最多 10 个）。
6. 显示说明时去掉别的平台的小节：语言块里标题正好是另一个平台名（`macOS` 或 `Windows`，不分大小写）的小节整个不显示，
   到下一个级别相同或更高的标题为止；本平台的小标题也去掉，只留它下面的内容。
7. 地址的核对分两种：
   - 发布页（会在浏览器里打开）：仍必须是本仓库的 GitHub Release 地址，规则不变。
   - 附件：来自验过签的清单，只要求是 https、没有用户信息、反斜杠与控制字符。文件的真伪由清单里的 SHA-256 保证；
     Windows 另外照旧核对签名的 `SHA256SUMS.txt`，macOS 另外照旧核对代码签名的指定要求。
8. 测试地址：`EVEO_UPDATE_FEED_URL` 指向一份清单，只用这一个源；附件仍须与它同源。验签用测试公钥
   `EVEO_UPDATE_TEST_PUBLIC_KEY`（64 位十六进制，只在测试地址下生效，正式地址下忽略）。

已安装的 1.4.x 及更早的客户端仍读 GitHub 的 Release 接口，不认平台标记，所以只改了一个平台的版本仍会提示它们一次。
1.5.0 两个平台都发，装上 1.5.0 之后就按平台提示了。

两端的解析与验签用同一组样例核对：`shared/fixtures/update-manifest/`（测试私钥、由脚本生成的信封与期望值）。

## 5 发布流程里的变化

`release.yml` 的 `publish` 任务：

1. 对每个平台，按发布说明的标记找出它的最新版本。就是本次版本时用本次的附件；是更早的版本时，从那个版本的 Release
   下载安装包、`SHA256SUMS.txt` 与签名，先验签、再核对哈希。
2. `scripts/build_update_manifest.py build` 生成清单正文，用签 `SHA256SUMS.txt` 的同一把私钥签名（带第 2.1 节的前缀），
   `envelope` 包成 `update-manifest.json`，作为附件放进 Release（附件数从 7 变为 8）。
3. 建 Release、核对 latest，与以前相同。

之后的 `cdn` 任务（配好 R2 才运行，可以单独重跑）：

1. 把各平台 `latest` 指向的文件传到 R2 的 `v<版本>/`，已存在的跳过。
2. 最后上传 `update-manifest.json`。顺序保证 R2 上的清单只指向已经在的文件。

在 `cdn` 任务完成之前，GitHub 上的清单里已经有 R2 的地址：这期间从 R2 下载会 404，应用自动换到 GitHub 的地址。

演练只生成清单作为草稿 Release 的附件，不运行 `cdn`。

## 6 R2 的配置

| 项 | 值 | 在哪里 |
| --- | --- | --- |
| 存储桶 | `eve-o-preview` | `release.yml` 的 `R2_BUCKET` |
| 公开地址 | `https://eveo.deepai.wiki`（R2 的自定义域名，经 Cloudflare 的 CDN） | `release.yml` 的 `R2_PUBLIC_BASE_URL` |
| 账号 ID | Cloudflare 账号 ID | secret `R2_ACCOUNT_ID` |
| 访问密钥 | 只对这个桶有读写权限的 R2 API 令牌 | secrets `R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY` |

不用 `r2.dev` 的地址：它有限速、不走缓存。三个 secret 缺任何一个时，清单里只有 GitHub 的地址，`cdn` 任务跳过上传。

`cdn` 任务用 AWS CLI 经 R2 的 S3 接口（`https://<账号 ID>.r2.cloudflarestorage.com`，region `auto`）上传。
它可以单独重跑：已在 R2 上的版本文件跳过，清单每次覆盖。

应用内置的 R2 清单地址在 `UpdateFeed.productionManifestURLs`（macOS）与 `feed::PRODUCTION_MANIFEST_URLS`（Windows），
与 `R2_PUBLIC_BASE_URL` 一致。换域名时要先发一个同时内置新旧地址的版本。
