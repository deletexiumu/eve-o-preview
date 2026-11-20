<p align="center"><img src="packaging/AppIcon.png" width="128" alt="EVE-O Preview for macOS 图标"></p>

# EVE-O Preview for macOS

[English](README.md) | **简体中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Русский](README.ru.md)

EVE-O Preview for macOS 给每个运行中的 EVE Online 客户端显示一个实时缩略图。点击缩略图或按全局热键，即可切换到对应的客户端。

本项目按上游 [EveOPlus/eve-o-preview](https://github.com/EveOPlus/eve-o-preview)（Windows 版，GPL-3.0）的功能，用 Swift 在 macOS 上重新实现。我们没有移植上游的 C# 源码，界面与配置文件格式也与上游不同。
本项目以 GNU 通用公共许可证第 3 版或任何更新的版本（GPL-3.0-or-later）发布，与源码文件头的 SPDX 标识一致；上游以 GPL-3.0 发布。许可证全文见 [LICENSE](LICENSE)。

本仓库最初是 EveOPlus/eve-o-preview 在 GitHub 上的 fork，从 v1.0 起迁为独立仓库。本项目是独立项目，与 Windows 版没有共用代码，也不由上游作者维护。

## 功能

- 自动发现 EVE 客户端：客户端启动、退出、登录后改名时自动更新。
- 实时缩略图：每个客户端一条 ScreenCaptureKit 捕获流，尺寸与帧率可调。
- 缩略图面板：不抢焦点、出现在所有空间，可设置是否置顶。默认带 2 点浅灰边框，便于区分相邻的缩略图；颜色、粗细可调，也可以关掉。
- 切换：左键点缩略图切到对应客户端，Ctrl+点击最小化。右键菜单提供最小化、全部最小化、跳过循环、隐藏、恢复默认尺寸。
- 叠层：角色名标题、活动客户端的高亮边框（可按角色设颜色，打开时代替浅灰边框）、跳过循环的标记。
- 悬停放大（9 个锚点）与透明度。
- 可见性：隐藏活动客户端的缩略图；前台不是 EVE 时隐藏（带延迟）；按角色隐藏；全部隐藏。
- 布局：拖动移动、拖动缩放，吸附到其他缩略图与屏幕边缘，可锁定布局。每个角色分别保存位置与尺寸；登录界面的客户端使用单独的起始位置。
- 循环组：前进与后退热键、本次会话内跳过；每角色直达热键；登录客户端循环热键；全部隐藏与全部最小化热键。热键可以用鼠标中键与侧键，每条热键可设为全局生效或只在 EVE 内生效。
- 战斗提醒（默认关闭）：读取游戏日志，角色受到攻击时它的缩略图闪烁。
- 配置方案：新建、克隆、改名、删除、切换。
- 更新：检查 GitHub 上的新版本，核对下载文件与代码签名后在应用内安装（见[更新](#更新)）。
- 报告问题：生成脱敏的诊断 zip，并打开预填好的 GitHub Issue；应用意外退出后，下次启动时提示报告（见[报告问题](#报告问题)）。
- 菜单栏图标，代替 Windows 版的托盘图标。
- 设置窗口共 8 页：客户端、预览与布局、切换与热键、提醒、配置方案、通用、权限、关于。
- 界面语言：英文（默认）、中文、俄文、日文、韩文，在「通用」页切换，也可以选「跟随系统」，切换后立即生效。俄、日、韩文的译文由机器生成，欢迎指正。

## 未移植的上游功能

| 上游功能 | 原因 |
| --- | --- |
| 帧率限制、选择性静音（Robin 注入） | 上游向 Windows 进程注入 DLL 实现，macOS 没有对应的公开机制 |
| CPU 亲和性 | 依赖 Windows CPU Sets；Apple Silicon 没有按进程指定核心的公开接口 |
| 战斗日志增强（Augments）中的伤害数字、DPS、维修量、星系叠层，FC 静态数据 | 独立的大型子系统，不属于「预览与切换」；只移植了「受到攻击时闪烁」 |
| 主题、Legacy 界面、自定义右键菜单样式 | macOS 版跟随系统外观 |
| 兼容捕获模式（`PrintWindow`） | ScreenCaptureKit 是唯一的捕获方式 |
| 低级键盘钩子 | 键盘热键用 Carbon 全局热键；只有绑定了鼠标按键时才建立鼠标事件监听 |

区域（Regions）与拖放停靠、多选与成组移动、撤销、吸附参考线、导入 Windows 版配置、登录时启动，计划在 v1 之后再做。

## 运行要求

- macOS 14 或更高版本，Apple Silicon 或 Intel 均可。发布的 dmg 内是通用二进制。
- EVE 客户端宜使用窗口模式。原生全屏的客户端在独立的空间里，切换时会有空间切换动画。
- 从源码构建需要 Xcode 或 Command Line Tools（Swift 6）。

## 安装

### 下载发布版

1. 从 [Releases](https://github.com/deletexiumu/eve-o-preview-macos/releases) 页面下载 `EVE-O-Preview-<版本号>.dmg`。
2. 打开 dmg，把 `EVE-O Preview.app` 拖进「应用程序」文件夹。
3. 打开应用。菜单栏出现图标，首次启动时自动打开设置窗口的「权限」页。

本项目没有 Apple 开发者 ID，发布版用本项目自己的自签名证书签名，没有经过公证。首次打开时，系统会拦截应用，提示无法验证开发者。按以下步骤打开：

1. 打开「系统设置 > 隐私与安全性」。
2. 向下滚动到关于 EVE-O Preview 的提示，点「仍要打开」，再确认。

如果系统提示应用「已损坏，无法打开」，或者不想走上面的步骤，可以在终端里去掉隔离属性：

```sh
xattr -dr com.apple.quarantine "/Applications/EVE-O Preview.app"
```

**注意：** 每个发布版都用同一张证书签名，升级后系统保留屏幕录制与辅助功能权限。如果升级后权限失效，用[权限](#权限)一节末尾的 `tccutil` 命令清除后重新授予。

从 1.1.0 起应用可以自行更新（见[更新](#更新)）。1.0.0 没有更新功能，要手动装一次 1.1.0：下载 dmg，替换「应用程序」里的应用。1.0.0 与之后的版本用同一张证书签名，权限会保留。

每个发布版还附带 `.tar.gz` 与 `.zip` 两种源码包和 `SHA256SUMS.txt`。要核对下载的文件，在下载目录里运行 `shasum -a 256 --ignore-missing -c SHA256SUMS.txt`。

### 从源码构建

1. 在仓库根目录运行 `scripts/build-app.sh`。脚本编译发布版，组装并签名 `dist/EVE-O Preview.app`。
2. 把 `dist/EVE-O Preview.app` 拖进「应用程序」文件夹。
3. 打开应用。

脚本读以下环境变量：

| 变量 | 作用 | 默认值 |
| --- | --- | --- |
| `VERSION` | 写进 `Info.plist` 的版本号 | `VERSION` 文件的内容 |
| `SIGN_IDENTITY` | 代码签名身份 | 钥匙串里有 `EVEO Preview Dev` 时用它，否则 ad-hoc 签名（`-`） |
| `UNIVERSAL` | 设为 `1` 时分别编译 arm64 与 x86_64，再用 `lipo` 合成通用二进制 | 不设：只编译本机架构 |

如果 `packaging/AppIcon.png` 存在，脚本会用它生成应用图标。

`scripts/package-release.sh` 先运行 `build-app.sh`，再把 dmg、源码包和 `SHA256SUMS.txt` 写到 `dist/release/`。CI 用的就是这个脚本。

## 权限

应用用到以下系统权限，都在「系统设置 > 隐私与安全性」里授予。设置窗口的「权限」页显示它们的状态，并提供请求按钮与系统设置的跳转。

| 权限 | 用途 | 缺少时 |
| --- | --- | --- |
| 屏幕录制 | 捕获客户端画面，读取窗口标题 | 缩略图显示占位画面；没有辅助功能权限时，标题也读不到，客户端显示为 `EVE (PID)` |
| 辅助功能 | 还原、提升、最小化客户端窗口，读取窗口标题，拦截鼠标热键 | 只能激活客户端进程，已最小化的窗口还原不了；「最小化」与「全部最小化」菜单项置灰；鼠标热键不生效，键盘热键照常 |
| 文稿文件夹 | 战斗提醒读取 `~/Documents/EVE/logs/Gamelogs` | 只在打开战斗提醒时请求；拒绝后「提醒」页显示原因，其他功能不受影响 |

授予屏幕录制权限后，通常要重新启动应用才生效，「权限」页有「重新启动」按钮。辅助功能权限授予后立即生效。

### 用自签名证书签名

系统按代码签名识别应用并记录授权。ad-hoc 签名没有稳定的身份，每次重新构建后，系统都把它当成另一个应用，两项授权都会失效。自己构建时宜用自签名证书：

1. 打开「钥匙串访问」，选菜单「钥匙串访问 > 证书助理 > 创建证书」。
2. 名称填 `EVEO Preview Dev`，身份类型选「自签名根证书」，证书类型选「代码签名」，然后创建。
3. 运行 `scripts/build-app.sh`。脚本在钥匙串里找到这个证书时自动使用它；也可以用 `SIGN_IDENTITY="EVEO Preview Dev" scripts/build-app.sh` 指定。
4. 如果系统询问是否允许 `codesign` 使用钥匙串里的私钥，选「始终允许」。

如果授权记录错乱，运行以下两条命令，再重新授权：

```sh
tccutil reset ScreenCapture io.github.deletexiumu.eveopreview-macos
tccutil reset Accessibility io.github.deletexiumu.eveopreview-macos
```

## 使用

### 缩略图手势

左键按下立即切换，不等松开，所以移动与缩放用右键拖动或 Option+左键拖动。

| 操作 | 手势 |
| --- | --- |
| 切换到该客户端 | 左键按下 |
| 最小化该客户端 | Ctrl+左键按下 |
| 打开菜单 | 右键单击（按下到松开之间移动不到 4 点） |
| 移动 | 右键拖动，或 Option+左键拖动 |
| 缩放 | 同移动的手势，从缩略图边缘 12 点以内开始拖动 |
| 临时不吸附 | 拖动时按住 Shift；缩放时按住 Shift 同时保持宽高比 |

打开「锁定布局」后，移动与缩放不起作用，切换、最小化与菜单照常。

### 热键

热键在设置窗口的「切换与热键」页录制：点按钮后按下组合键或鼠标按键，Esc 取消，Delete 清除。一个动作可以绑定多个组合。

- 循环组：每组有前进与后退热键，在组内在线、未被跳过的角色之间按顺序切换，到末尾后回到开头。
- 角色直达热键：切到指定角色的客户端。
- 通用热键：显示或隐藏全部缩略图、全部最小化、在登录界面的客户端之间循环。

键盘热键应包含 Ctrl、Option、Command 之一；F1～F20 与小键盘数字可以单独使用。Cmd+Tab、Cmd+Space、Cmd+Q 等系统组合会被拒绝。热键有问题时，设置窗口在它旁边显示原因。

鼠标热键：

- 可以录制中键与侧键（配置里写作 `Mouse3`～`Mouse32`），可以带修饰键，如 `ctrl+Mouse4`。左键与右键不能绑定。
- 热键触发时，这次点击（按下、拖动、松开）不会传给前台应用，游戏里绑在同一个按键上的动作不会执行。
- 需要辅助功能权限。

作用范围：

- 每条热键可设为「全局」或「仅 EVE 内」，配置里写作后缀 `@global`、`@game`。没有后缀的热键跟随配置方案的默认作用范围。
- 「仅 EVE 内」的热键只在 EVE 客户端位于前台时生效，在其他应用里按下时照常传给那个应用。
- 新录制的鼠标热键默认只在 EVE 内生效，避免在所有应用里拦截侧键。
- 菜单栏菜单的「热键只在 EVE 内生效」可一键切换默认作用范围。

### 战斗提醒

在设置窗口的「提醒」页打开。打开后应用读取 `~/Documents/EVE/logs/Gamelogs` 里客户端新写入的游戏日志，按日志文件头的收听者把日志对应到角色；某个角色受到攻击时，它的缩略图边框与画面闪烁 3 秒。

- EVE 客户端要开启游戏日志记录（默认开启）。
- 被打空（未命中）默认也提醒，可以关掉；可设最小伤害值、闪烁颜色与时长。
- 打开「离开 EVE 时隐藏」时，受到攻击的角色的缩略图会临时显示。
- 系统设置里打开「减弱动态效果」时，闪烁改为常亮。
- 应用只读日志，不写入、不修改，也不向游戏发送输入。
- 第一次打开时，系统会询问是否允许访问「文稿」文件夹。日志在其他位置时，可以在「提醒」页选择目录。
- 中文客户端的日志格式已用真实日志核对。日文、俄文伤害行已用真实客户端日志核对（上游的录制样例），未命中只按模板推出。英、德、法、西、韩文按上游的模板推出，尚未用真实日志核对。

### 菜单栏

菜单栏图标与应用图标同为八边形框里的分子图案。菜单提供：显示或隐藏全部缩略图、切换配置方案、全部最小化、热键只在 EVE 内生效、检查更新…、报告问题…、设置、退出。有可用的更新或上次运行意外退出时，图标上出现一个圆点，菜单顶部多出对应的一项。缺少权限时多一项权限提示。如果你在系统的录制指示器里停止了某个客户端的捕获，菜单里会多一项「恢复捕获」。

### 更新

应用在启动时和每天检查一次 GitHub 上的新版本。要关掉自动检查，在「设置 > 通用 > 更新」里关掉「自动检查更新」；菜单栏菜单的「检查更新…」仍可随时手动检查。

有新版本时，窗口按界面语言显示发布说明（没有对应译文时显示英文），提供「安装更新」「跳过此版本」「稍后」。EVE 客户端在前台时，窗口等你切走后才出现，也不会自己抢键盘焦点；菜单栏图标上的圆点表示有更新在等待。「跳过此版本」只停止该版本的自动提醒，「检查更新…」仍会显示它。

「安装更新」下载 dmg，按 `SHA256SUMS.txt` 核对，确认新应用与正在运行的应用用同一张证书签名，然后替换应用并重新启动。任何一步失败，已安装的应用都保持不变。打开「自动安装更新」后，更新在后台下载，等你退出应用或在菜单栏菜单里点「重新启动以更新到 X.Y.Z」时安装；应用不会自己重新启动。

以下构建只显示原因和「打开发布页」按钮，不能在应用内安装：ad-hoc 或本机证书签名的构建、从磁盘映像或被系统转移到随机位置运行的应用、所在文件夹没有写权限的应用、装在 FAT 或 exFAT 卷上的应用。

### 报告问题

在菜单栏菜单或「通用」页选「报告问题…」，或者在应用意外退出后的提示里选择报告。窗口列出报告里的每个文件，并显示脱敏后的内容：环境摘要、不含名字的配置摘要、应用日志（最多 2 MiB）和最多 3 份 macOS 崩溃报告。点「只生成报告」或「生成报告并打开 GitHub」之前，不会生成任何文件。zip 存到 `~/Library/Application Support/EVE-O Preview/Reports/`（保留最新的 3 个），并在访达中显示；「生成报告并打开 GitHub」还会在浏览器里打开预填好的 Issue。zip 由你自己拖进 Issue，应用不上传任何文件。

macOS 用户名、全名、主目录路径与电脑名替换为 `[user]` 与 `[host]`。EVE 角色名替换为 `[character-1]`、`[character-2]` 等，崩溃报告里的设备标识替换为 `[redacted]`。只替换应用知道的名字：没在配置里出现过、也没作为运行中的客户端出现过的角色名不会被替换。如果某个名字是常用词，日志里其他地方的同一个词也会被替换。生成报告前可以阅读每个文件，取消勾选不想附上的文件。

应用在 `~/Library/Logs/EVE-O Preview/` 下最多保留 5 个日志文件，每个 1 MiB。角色名与窗口标题记为 `<private>`。在「通用」页打开「详细日志」可记录调试信息，「在访达中显示日志」打开日志文件夹。如果崩溃后没有出现提示，可以手动把 `~/Library/Logs/DiagnosticReports/EVEOPreview-<日期>.ips` 附到 Issue 里。

## 隐私

1.0.0 不发任何网络请求。从 1.1.0 起应用只访问 GitHub，并且只为了更新：

- 检查更新：「自动检查更新」打开时，在启动后与每天请求一次 `api.github.com/repos/deletexiumu/eve-o-preview-macos/releases/latest`；你点「检查更新…」时也请求一次。
- 安装更新：从 Release 下载 `SHA256SUMS.txt` 与 dmg。

请求里只有 `User-Agent` 请求头里的应用版本号、固定的 `Accept-Language: en` 和一个缓存标签；不发送角色名、配置、日志、硬件信息、系统版本或任何标识符，不用 cookie。GitHub 能看到的是你的 IP 地址和请求时间。应用没有遥测，也不自动上传崩溃信息：「报告问题…」只在本机生成 zip，并打开一个网页，提交与否由你决定。

应用在以下位置存放数据。要完全卸载，删除应用时一并删除它们和 `~/Library/Application Support/EVE-O Preview/config.json`：

| 位置 | 内容 |
| --- | --- |
| `~/Library/Logs/EVE-O Preview/` | 应用日志，最多约 5 MiB |
| `~/Library/Application Support/EVE-O Preview/session.json`、`state.json` | 会话标记；更新与诊断的记录 |
| `~/Library/Application Support/EVE-O Preview/Reports/` | 你生成的问题报告 zip，已脱敏（保留最新的 3 个） |
| `~/Library/Caches/io.github.deletexiumu.eveopreview-macos/Updates/` | 下载的更新文件，安装后删除 |

## 配置文件

配置保存在 `~/Library/Application Support/EVE-O Preview/config.json`。一个文件装下全部配置方案。

- 设置改动后 0.5 秒自动保存，退出时再保存一次。
- 文件损坏时，原文件被改名为 `config.corrupt-<日期时间>.json`，应用使用默认配置。
- 文件来自更新的版本时，应用使用默认配置运行，本次会话不写盘，不覆盖原文件。

「配置方案」页有「在访达中显示」按钮。

## 开发

| 命令 | 作用 |
| --- | --- |
| `swift build` | 编译全部目标 |
| `swift test` | 运行 Core 的单元测试（swift-testing） |
| `EVEO_FAKE=1 swift run EVEOPreview` | 演示模式：3 个假客户端与生成的动画画面，不需要 EVE 与任何权限 |
| `python3 scripts/check_quality.py` | 检查注释率、文件行数与函数行数 |
| `scripts/build-app.sh` | 组装并签名 `.app` |
| `scripts/package-release.sh` | 在 `dist/release/` 下生成 dmg、源码包与校验和 |
| `swift run EVEOProbe gamelog [目录] [--follow 秒数]` | 统计游戏日志各类战斗行的数量，诊断战斗提醒 |
| `swift run EVEOProbe mousetap <秒数> [--swallow <按钮号>]` | 打印鼠标按键编号，诊断鼠标热键 |
| `swift run EVEOProbe update feed [地址]` | 获取并解析发布信息 |
| `swift run EVEOProbe update verify <新应用> <基准应用>` | 核对新应用是否满足基准应用的指定要求 |
| `swift run EVEOProbe update prepare <地址> [--cache 目录]` | 下载并核对更新，不安装 |
| `scripts/make-update-test-feed.sh [版本号]` | 由 `dist/release/` 生成本地更新测试用的 `feed.json` |

演示模式的配置写到同目录下的 `config-fake.json`，不影响正式配置。以下环境变量用于调试：

| 变量 | 作用 |
| --- | --- |
| `EVEO_CONFIG_PATH` | 使用指定的配置文件 |
| `EVEO_LANG` | `en`、`zh`、`ru`、`ja` 或 `ko`，覆盖配置里的界面语言 |
| `EVEO_FAKE_DENY` | 演示模式下假装缺少权限，取值 `screen`、`ax` 或 `screen,ax` |
| `EVEO_FAKE_STOP_AFTER` | 演示模式下，到指定秒数时假装用户停止了第二个客户端的捕获 |
| `EVEO_SETTINGS_PAGE` | 启动后直接打开设置窗口的某一页，如 `previews` |
| `EVEO_LOG_DIR` | 把日志文件写到另一个文件夹（默认 `~/Library/Logs/EVE-O Preview/`） |
| `EVEO_STATE_DIR` | 把 `state.json` 与 `session.json` 放到另一个文件夹 |
| `EVEO_LOG_PRIVATE` | 设为 `1` 时，私有值只在系统日志（控制台）里显示原文；日志文件里一律是 `<private>` |
| `EVEO_UPDATE_FEED_URL` | 改为向这个地址检查更新；只接受 `https`，或回环主机的 `http`。本机证书签名的构建可以从它安装，签名核对不放宽 |
| `EVEO_UPDATE_UI_STATE` | 演示模式下，把更新界面设成样例状态：`available`、`notifyonly`、`downloading`、`ready`、`failed` 或 `uptodate` |
| `EVEO_FAKE_CRASH` | 演示模式下设为 `1`，假装上次运行崩溃，用来查看崩溃报告的提示 |

源码分 3 个模块：`EVEOPreviewCore` 是纯逻辑层，`EVEOPreviewPlatform` 封装 AppKit、ScreenCaptureKit、辅助功能与 Carbon 热键，`EVEOPreview` 是应用本体。架构说明见 [docs/architecture.md](docs/architecture.md)。

**注意：** 用 `swift run` 直接运行可执行文件时，系统把权限记在终端应用名下，不记在 `EVE-O Preview.app` 名下。

### CI 与发布

`.github/workflows/build.yml` 跑在 GitHub 托管的 macOS 运行器上：

- 每个向 `main` 发起的 PR 和每次推送到 `main`，都会运行质量门禁与单元测试，再打包通用二进制的 dmg 和源码包。产物作为工作流制品上传，名为 `EVE-O-Preview-<版本号>-pr.<编号>.<提交>`（推送时为 `-dev.<提交>`），保留 30 天。
- 推送 `v*` tag 时打包同样的文件，并发布为 GitHub Release。tag 应与 `VERSION` 文件一致。如果 `docs/release-notes/<tag>.md` 存在，它就是 Release 的说明。

发布新版本时，在 PR 里修改 `VERSION` 文件并新增 `docs/release-notes/v<版本号>.md`，合并后在 `main` 上打 tag：`git tag v<版本号> && git push origin v<版本号>`。

附件名（`EVE-O-Preview-<版本号>.dmg`、`SHA256SUMS.txt`）、dmg 的结构、签名证书与发布说明的格式是与应用内更新之间的约定，CI 每次构建都会核对。发布说明英文在前，包在 `<!-- lang:en -->` 与 `<!-- /lang:en -->` 之间，之后是用同样方式标记的 zh、ja、ko、ru 折叠块；`scripts/check_release_notes.py` 检查这些标记。细节见 [docs/architecture.md](docs/architecture.md) 的 9.5～9.7 节。

## 声明

本工具只切换窗口焦点，不向多个客户端广播输入，不读取或修改游戏内存，与上游的边界相同。使用前请自行阅读 EVE Online 的最终用户许可协议。

应用只在检查和下载更新时访问 GitHub，不发送个人数据（见[隐私](#隐私)）。

EVE Online 及相关标志是 CCP ehf. 的商标。本项目与 CCP 没有关联，也未获其认可。

应用图标沿用上游 EveOPlus/eve-o-preview 的分子图标（GPL-3.0），背景由 `scripts/make-app-icon.py` 绘制，不含 CCP 的商标或游戏美术。
