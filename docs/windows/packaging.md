# Windows 版的打包与发布

本文说明 Windows 版怎样从源码变成一个 GitHub Release，以及第一次发布前要做的一次性准备。发布契约（附件的名字与内容）见[架构文档 6.2 节](architecture.md#62-发布契约windows)，自动更新怎样使用这些附件见 6.3 节。

## 1 总览

1.4.0 起，macOS 与 Windows 用同一个版本号，在同一个 tag `v<版本>` 下发布同一个 Release。推送这个 tag 后，`.github/workflows/release.yml` 依次运行：

| 任务 | 运行器 | 做什么 |
| --- | --- | --- |
| `versions` | Linux | 核对 `macos/VERSION`、`windows/VERSION`、`windows/Cargo.toml` 三处版本号相同，且等于 tag |
| `macos` | macOS | 调用 `macos.yml`：检查、构建、签名，打出 dmg 与源码包 |
| `windows` | Linux、Windows | 调用 `windows.yml`：与 PR 相同的检查，发布构建，打包，自检 |
| `publish` | Linux | 合并两个平台的校验和，用私钥签名，建 Release 并标为 latest；需要时另建一个兼容用的 `win-v<版本>` Release（见第 4 节） |

两个平台任何一个失败，`publish` 都不运行，不会出现只有一个平台的 Release。签名私钥只在 `publish` 任务里用。Windows 运行器上只有公钥，它随发布构建编进 exe。

1.4.0 以前 Windows 单独发布，tag 是 `win-v<版本>`，Release 不标为 latest。这些 Release 保留不动。

## 2 打包

`package` 任务做的事，也可以在本机的 Windows 上照着做（私钥除外）：

1. 发布构建：`cargo build --release --locked -p eveo-app -p eveo-probe`，环境变量：
   - `EVEO_BUILD_LABEL`：构建标签，正式发布时等于版本号；演练时是 `<版本>-rehearsal.<运行号>`。它写进 exe 的版本资源（`BuildLabel`），自动更新用它核对解出的 exe 就是要装的版本。
   - `EVEO_UPDATE_PUBLIC_KEY`：`windows/packaging/update-public-key.txt` 的内容。没有公钥的构建只提示有更新、不安装。
2. `pwsh packaging/package.ps1 -Version <标签> -OutDir dist`，产出：
   - `EVE-O-Preview-<标签>-windows-x64.zip`：根目录下的 `EVE-O Preview.exe`、`LICENSE.txt`、`README.txt`（`windows/packaging/README.txt`）；
   - `eve-o-preview-<标签>-windows-source.zip`：这个提交的 `windows/` 与 `shared/`；
   - `SHA256SUMS.txt`：上面两个文件的 SHA-256，LF 行尾。
3. 自检：`eveo-probe package-check` 用应用自己的解包与版本核对检查 zip：正好三个文件、exe 是 x64、ProductVersion 等于版本号、BuildLabel 等于构建标签（演练时多一段 `-rehearsal.<运行号>`）、exe 里带着公钥。

## 3 签名密钥（第一次发布前做一次）

自动更新只安装签名对得上的更新包。密钥对由维护者在自己的电脑上生成，私钥不进仓库、不进聊天、不进日志。

1. 在 macOS 或 Linux 上，`windows/` 目录里运行：

   ```sh
   cargo run -q -p eveo-core --example update_signing_key -- ~/eveo-update-signing-key.txt > packaging/update-public-key.txt
   ```

   私钥种子（一行 64 位十六进制）写到给定的文件，权限 600，已存在时不覆盖。公钥写进 `packaging/update-public-key.txt`。
2. 把私钥文件的内容放进仓库的 Actions secret `WINDOWS_UPDATE_SIGNING_KEY`。例如用 GitHub CLI：`gh secret set WINDOWS_UPDATE_SIGNING_KEY < ~/eveo-update-signing-key.txt`。
3. 把私钥文件离线备份（例如放进密码管理器），然后删掉本机的文件。私钥丢了，已安装的版本就再也验不过新包，只能让用户手动下载。
4. 提交 `packaging/update-public-key.txt`。

`publish` 任务签名前会核对 secret 的私钥与提交的公钥是一对，不配对时失败。

换密钥：只有私钥泄露时才换。换了之后，旧版本验不过用新私钥签的包，所以要先发一个用旧私钥签、内置新公钥的过渡版，等大多数用户更新之后再换 secret。

## 4 发一个版本

1. 开一个发版 PR：
   - 改 `macos/VERSION`、`windows/VERSION` 与 `windows/Cargo.toml` 的 `[workspace.package] version`，三者必须相同（`scripts/check_versions.py`，CI 核对）。只改了一个平台也一起升版本号；
   - 写发布说明 `docs/release-notes/v<版本>.md`，格式见下；
   - 版本号带 `-`（如 `1.5.0-beta.1`）时 Release 标为预发布、不标 latest。1.5.0 起预发布版不写进更新清单，应用不会提示它。
2. 合并后在 main 上打 tag 并推送：`git tag -a v<版本> -m v<版本> && git push origin v<版本>`。
3. 看 Actions 里这次 `release.yml` 的运行：成功后 Release 页面有 8 个附件（dmg、Windows zip、两个源码包、`SHA256SUMS.txt`、它的签名与
   更新清单 `update-manifest.json`），`/releases/latest` 指向这个 tag。之后的 `cdn` 任务把清单与安装包传到 Cloudflare R2
   （[更新清单与分发](../update-manifest.md) 第 5、6 节），失败时可以单独重跑这个任务。

Release 已存在时 `publish` 任务失败，不覆盖附件。发错了要删掉 Release 与 tag，改版本号重发。

### 4.1 发布说明

一个版本一份，两个平台共用，英文在前、其余 7 种语言各一个折叠块，语言块的标记与 macOS 原来的相同（`scripts/check_release_notes.py` 核对）。
第一行是平台标记 `<!-- platforms: macos windows -->`，写这个版本改动了哪些平台：只改了一个平台时只写它，另一个平台的应用就不会提示这个版本。
每个语言块里按平台分小节：两端都有的改动写在最前面（标题不要正好是平台名），然后是「macOS」「Windows」两个小标题，某个平台没有改动就省掉它的小标题。
1.5.0 起两个平台的应用只显示对应语言块里本平台的部分（[更新清单与分发](../update-manifest.md) 第 1 节）。

1.4.0 以前的说明留在 `docs/release-notes/macos/` 与 `docs/release-notes/windows/`，不再新增。

### 4.2 与旧版本的兼容

- 1.5.0 起两个平台都读更新清单。1.4.x 及更早的版本仍读 GitHub 的 Release 接口、不认平台标记，所以只改了一个平台的版本仍会提示它们一次。
- macOS：1.4.x 及更早的版本读 `/releases/latest`，按名字取 dmg 与 `SHA256SUMS.txt`，校验和文件里多出的 Windows 行不影响它。不需要别的措施。
- Windows：1.4.0 以前的版本只认 `win-v` 开头的 tag。`release.yml` 的 `WINDOWS_LEGACY_TAG_VERSIONS` 列出的版本，`publish` 会另建一个 tag 为 `win-v<版本>` 的 Release（不标 latest），只放 Windows 的 4 个附件与单独签名的校验和，让旧版本能自动更新上来。现在列表里只有 1.4.0：装上 1.4.0 之后客户端就认 `v` 开头的 tag 了。
- Windows 1.4.0 起两种 tag 都认；`v` 开头的 Release 必须带这个版本的 Windows zip 才算数，所以只有 macOS 附件的旧 Release（1.3.2 及以前）会被跳过。

## 5 演练

在 Actions 里手动运行 `release.yml`（「演练发布」默认勾选）：两个平台都打包、签名，建一个草稿 Release（tag 名 `v<版本>-rehearsal.<运行号>`，不公开、不打 tag），不建兼容 Release。看过附件后在 Releases 页面删掉这个草稿。演练同样需要公钥、secret 与 macOS 的签名证书。

单独手动运行 `macos.yml` 或 `windows.yml` 只做检查与构建，产物作为工作流制品上传，不建 Release。
