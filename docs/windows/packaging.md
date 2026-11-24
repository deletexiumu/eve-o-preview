# Windows 版的打包与发布

本文说明 Windows 版怎样从源码变成一个 GitHub Release，以及第一次发布前要做的一次性准备。发布契约（附件的名字与内容）见[架构文档 6.2 节](architecture.md#62-发布契约windows)，自动更新怎样使用这些附件见 6.3 节。

## 1 总览

推送 `win-v<版本>` tag 后，`.github/workflows/windows.yml` 依次运行：

| 任务 | 运行器 | 做什么 |
| --- | --- | --- |
| `core`、`build` | Linux、Windows | 与 PR 相同的检查；另核对 tag 与 `windows/VERSION` 一致 |
| `package` | Windows | 发布构建，打包，自检 |
| `release` | Linux | 用私钥给校验和签名，建 Release（不标为 latest），核对 `/releases/latest` 仍是 macOS 的 tag |

签名私钥只在 `release` 任务里用。Windows 运行器上只有公钥，它随发布构建编进 exe。

## 2 打包

`package` 任务做的事，也可以在本机的 Windows 上照着做（私钥除外）：

1. 发布构建：`cargo build --release --locked -p eveo-app -p eveo-probe`，环境变量：
   - `EVEO_BUILD_LABEL`：构建标签，正式发布时等于版本号；演练时是 `<版本>-rehearsal.<运行号>`。它写进 exe 的版本资源（`BuildLabel`），自动更新用它核对解出的 exe 就是要装的版本。
   - `EVEO_UPDATE_PUBLIC_KEY`：`windows/packaging/update-public-key.txt` 的内容。没有公钥的构建只提示有更新、不安装。
2. `pwsh packaging/package.ps1 -Version <标签> -OutDir dist`，产出：
   - `EVE-O-Preview-<标签>-windows-x64.zip`：根目录下的 `EVE-O Preview.exe`、`LICENSE.txt`、`README.txt`（`windows/packaging/README.txt`）；
   - `eve-o-preview-<标签>-windows-source.zip`：这个提交的 `windows/` 与 `shared/`；
   - `SHA256SUMS.txt`：上面两个文件的 SHA-256，LF 行尾。
3. 自检：`eveo-probe package-check` 用应用自己的解包与版本核对检查 zip：正好三个文件、exe 是 x64、版本资源等于标签、exe 里带着公钥。

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

`release` 任务签名前会核对 secret 的私钥与提交的公钥是一对，不配对时失败。

换密钥：只有私钥泄露时才换。换了之后，旧版本验不过用新私钥签的包，所以要先发一个用旧私钥签、内置新公钥的过渡版，等大多数用户更新之后再换 secret。

## 4 发一个版本

1. 开一个发版 PR：
   - 改 `windows/VERSION` 与 `windows/Cargo.toml` 的 `[workspace.package] version`，两者必须相同（CI 核对）；
   - 写发布说明 `docs/release-notes/windows/v<版本>.md`，格式与 macOS 的相同（语言块标记，见 `scripts/check_release_notes.py`）；
   - 版本号带 `-`（如 `0.9.0-beta.1`）时 Release 标为预发布，只推给正在运行预发布版的用户。
2. 合并后在 main 上打 tag 并推送：`git tag win-v<版本> && git push origin win-v<版本>`。
3. 看 Actions 里这次运行的 `release` 任务：成功后 Release 页面有 4 个附件，`/releases/latest` 仍是 macOS 的版本。

Release 已存在时 `release` 任务失败，不覆盖附件。发错了要删掉 Release 与 tag，改版本号重发。

## 5 演练

在 Actions 里手动运行 Windows 工作流，勾选「演练发布」：打包、签名，建一个草稿 Release（tag 名 `win-v<版本>-rehearsal.<运行号>`，不公开、不打 tag）。看过附件后在 Releases 页面删掉这个草稿。演练同样需要公钥与 secret。
