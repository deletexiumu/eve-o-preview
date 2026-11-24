# EVE-O Preview Windows 版与 monorepo 架构设计方案

- 日期：2026-11-23
- 依据：仓库 `deletexiumu/eve-o-preview-macos`（VERSION 1.2.2）的源码与 `docs/architecture.md`、`docs/design-v1.1.md`、`docs/design-intel-translate.md`（目录重组后在 `docs/macos/` 下）。
- 状态：2026-11-23 定稿。第 9.2 节的 14 个问题都按「建议」一列确定。过渡版 v1.3.0 已于同日发布（7.5 节）。
- 标注「待实测」的条目是在没有 Windows 机器的条件下写的，由 M3 的探针核实（8.3 节）。

## 0 结论摘要

| 问题 | 结论 |
| --- | --- |
| 语言 | Rust（stable，MSVC 工具链）+ `windows` crate（windows-rs）直接调 Win32 与 DWM |
| 缩略图与浮层 | 自绘的原生无边框窗口：DWM 缩略图画在 `WS_POPUP` 顶层窗口上，标题与闪烁画在伴随的分层窗口上 |
| 设置窗口、预警与翻译浮窗 | Slint（fluent 样式），Win11 上加 Mica、圆角与暗色标题栏，Win10 退回纯色背景 |
| Core 逻辑 | 把 Swift Core（约 1.5 万行）逐模块移植成不依赖 Windows 的 Rust crate，在 Linux 上跑测试；两端用 `shared/fixtures` 里的同一批用例对齐行为 |
| 分发 | 单个 exe 的便携 zip，自带更新器（校验和加 ed25519 签名）；之后加 winget 与微软商店 |
| 代码签名 | 先不签名发布测试版，同时申请 SignPath Foundation 的开源免费签名 |
| 仓库 | 改成 monorepo（`macos/`、`windows/`、`shared/`），仓库改名为 `eve-o-preview` |
| tag | macOS 永久用 `v*`，Windows 用 `win-v*` 且 Release 不标为 latest |
| 迁移顺序 | 先发 macOS 过渡版 v1.3.0（同时接受新旧仓库名），再重组目录，等至少 3 周后改名 |

最大的风险有三个：两份 Core（Swift 与 Rust）长期并存会出现行为漂移；云端没有 Windows 环境，平台层只能靠 CI 运行器与用户手工验证；没有代码签名时 SmartScreen 与杀毒软件会拦截。应对办法分别在第 5、8、6 节。

## 1 目标与范围

### 1.1 目标

1. 在 Windows 上提供与 macOS 版 1.2.x 对齐的功能，替代上游的 C# 版 EVE-O Preview。
2. 界面达到 Windows 11 的观感：Mica、圆角、暗色模式、清晰的高 DPI 显示。
3. 常驻内存小、启动快：多开玩家同时开着 5～20 个客户端，工具本身不应占资源。
4. 不注入游戏进程、不广播输入、不读游戏内存。只用公开的窗口接口、DWM 接口和游戏自己写的日志文件。

### 1.2 支持的 Windows 版本

| 系统 | 支持程度 | 说明 |
| --- | --- | --- |
| Windows 11 22H2 及以上（build 22621+） | 完整 | Mica、圆角、暗色标题栏都用公开接口 |
| Windows 11 21H2（build 22000） | 完整，无 Mica | 圆角可用；Mica 在这个版本只有未公开的接口，不用，退回纯色 |
| Windows 10 22H2（build 19045） | 功能完整，界面降级 | 无 Mica、无窗口圆角，暗色标题栏可用。见 2.4 节 |
| Windows 10 更早版本、Windows 8.1 及以下 | 不支持 | Per-Monitor DPI v2 与暗色标题栏的接口不全 |
| 架构 | 只发 x64 | EVE 没有 ARM64 的 Windows 客户端。ARM64 设备靠系统的 x64 模拟运行，不单独测试 |

### 1.3 功能清单（与 macOS 对齐）

「v1」后面的 M 编号是第 8 节的里程碑。

| 功能 | macOS 现状 | Windows | 说明 |
| --- | --- | --- | --- |
| 客户端发现（启动、退出、登录后改名） | 有 | v1（M3） | 按进程名与窗口类名，见 4.1 节 |
| 实时缩略图 | 有（ScreenCaptureKit） | v1（M3） | 用 DWM 缩略图，不占 GPU 拷贝，没有帧率设置 |
| 点击切换、Ctrl+点击最小化、右键菜单 | 有 | v1（M4） | |
| 标题、边框、活动客户端高亮、按角色设颜色 | 有 | v1（M4） | 画在伴随的分层窗口上，见 4.2 节 |
| 悬停放大（9 个锚点）、透明度 | 有 | v1（M4） | |
| 可见性规则（隐藏活动客户端、前台不是 EVE 时隐藏、按角色隐藏、全部隐藏） | 有 | v1（M4） | 规则在 Core，直接移植 |
| 拖动移动与缩放、吸附、锁定布局、每角色保存位置 | 有 | v1（M4） | |
| 循环组、每角色直达热键、全部隐藏与全部最小化热键 | 有 | v1（M4） | |
| 鼠标中键与侧键热键、热键作用范围（全局或只在 EVE 前台） | 有 | v1（M5） | 低级鼠标钩子，见 4.4 节 |
| 配置方案（新建、克隆、改名、删除、切换） | 有 | v1（M5） | |
| 菜单栏图标 | 有 | v1（M4） | 换成托盘图标 |
| 设置窗口（客户端、预览与布局、切换与热键、提醒、预警、翻译、配置方案、通用、环境检查、关于） | 有 | v1（M4 起，M5 完成） | macOS 的「权限」页换成「环境检查」页：本工具与客户端是否以管理员运行、日志目录与 Chatlogs／Gamelogs、窗口模式的建议（独占全屏分辨不出，只给建议） |
| 8 种界面语言 | 有 | v1（M5） | 文案来自 `shared/l10n` |
| 战斗提醒（受击闪烁） | 有 | v1（M6） | |
| 预警浮窗（ESI 查人名、跳数） | 有 | v1（M6） | |
| 聊天翻译浮窗（多个服务预设，密钥进系统凭据库） | 有 | v1（M6） | |
| 文件日志、诊断、异常退出检测、问题报告 | 有 | v1（M7） | |
| 更新检查与应用内安装（校验和、签名核对） | 有 | v1（M7） | 见第 6 节 |
| 开机启动 | 无（推迟） | v1（M7） | Windows 上只是写一个注册表值 |
| 单实例 | 系统保证 | v1（M4） | |
| 导入上游 C# 版的配置（位置、循环组、热键） | 无 | 之后（优先） | 降低老用户迁移的成本 |
| 与 macOS 版互相导入配置 | 无 | 之后 | 见 5.5 节 |
| 切换时最小化非活动客户端 | 无（推迟） | 之后 | DWM 对最小化窗口的缩略图行为待实测 |
| 区域与停靠、多选、成组移动、吸附参考线 | 无（推迟） | 之后 | 与 macOS 同步规划 |
| 预览其他应用 | 无（推迟） | 之后 | |
| winget 清单、微软商店上架 | 不适用 | 之后 | |
| CPU 亲和性 | 不移植 | 之后（低优先） | Windows 上可行，但不属于预览与切换 |
| 帧率限制、选择性静音（上游靠注入 DLL） | 不移植 | 不做 | 违背 1.1 节第 4 条 |
| 伤害数字、DPS、FC 数据 | 不移植 | 不做 | 与 macOS 一致 |
| 自定义主题、Legacy 界面 | 不移植 | 不做 | 跟随系统的明暗与强调色 |
| 兼容捕获模式（`PrintWindow`）、Windows.Graphics.Capture | 不适用 | 不做 | DWM 缩略图是唯一的后端 |

## 2 技术选型

### 2.1 语言对比

第四列是用户没有提到、但应当考虑的方案：Swift 6 已正式支持 Windows，而 macOS 的 Core 只依赖 Foundation。

| 维度 | Rust + windows-rs | C++（C++/WinRT） | C# .NET NativeAOT | Swift on Windows |
| --- | --- | --- | --- | --- |
| Win32 与 DWM 细节 | 好。`windows` crate 由微软按元数据生成，覆盖全部 Win32、COM、WinRT | 最好，原生头文件，资料最多 | 好。CsWin32 生成 P/Invoke；AOT 下回调与 COM 要按规则写 | 可用。`WinSDK` 模块能直接调 Win32，资料很少 |
| 单文件体积 | 约 8～15 MB（含 Slint），静态链接，无运行时 | 约 2～6 MB（不含界面库） | 纯 Win32 约 10～20 MB；带 WinUI 3 自包含约 40～80 MB | 要带运行时与 Foundation 的 DLL，约 50 MB 以上，做不成单文件 |
| 启动与常驻内存 | 启动几十毫秒，常驻约 15～40 MB | 同级 | AOT 启动快，常驻略高；带 WinUI 3 时约 80～150 MB | 中等 |
| 可测试性 | 好。`cargo test` 内置，纯逻辑 crate 在 Linux、macOS、Windows 都能跑 | 差。要自己选测试框架与构建系统 | 好。`dotnet test` 也能在 Linux 跑 | 好，而且现有测试可以直接用 |
| 在 Linux 容器里核对 Windows 代码 | 能。`cargo check --target x86_64-pc-windows-msvc` 不需要链接器，平台层的类型错误在云端就能发现 | 不能（要 MSVC） | 部分能。Win32 部分能编译，WinUI 3 的 XAML 编译与 AOT 发布只能在 Windows 上做 | 不能 |
| AI 辅助开发 | 好。编译器严格，错误信息能直接驱动修改；内存与线程问题多数在编译期暴露 | 差。未定义行为要靠运行才能发现，而我们没有可运行的环境 | 好。资料多；AOT 的裁剪与反射限制要到发布构建才报错 | 差。Windows 上的 Swift 资料太少 |
| 复用 macOS Core | 不能直接复用，要移植。两端都是带代数枚举的值类型语言，`Codable` 对 serde、`enum` 对 `enum`、协议对 trait，可以逐文件对译 | 要移植，模型差别大 | 要移植，模型接近 | 可以原样复用 Core 与测试 |
| 现代界面的出路 | Slint、windows-reactor、Tauri | WinUI 3（一等支持） | WinUI 3（一等支持） | 基本没有（swift-winrt 是第三方绑定） |

结论：选 Rust。

1. 决定性的理由是开发环境。云端是 Linux，用户是 Mac，没有一台随手可用的 Windows。Rust 能做到三件事：Core 与界面在 Linux 和 Mac 上原样运行；平台层在 Linux 上做类型检查；编译通过的代码里内存与线程错误很少。C++ 与 C# 加 WinUI 3 都做不到前两件。
2. 体积、启动与常驻内存符合 1.1 节第 3 条，单个 exe 能做便携分发。
3. C# 加 WinUI 3 的界面最正统，但体积与内存不合适，而且界面只能在 Windows 上构建与预览。
4. Swift on Windows 在「复用」一项上最好，仍不选：没有可用的界面方案，做不成单文件，Foundation 在 Windows 上的行为与 macOS 有差别（等于换一种方式引入漂移），工具链资料少。
5. 选 Rust 的代价是要维护两份 Core。这是本方案最大的长期成本，对策在 5.6 节。

### 2.2 界面分层

缩略图不需要界面库，设置窗口才需要好看，所以界面分三层，各用合适的手段。

| 层 | 内容 | 实现 | 理由 |
| --- | --- | --- | --- |
| A 缩略图层 | 每个客户端一个缩略图窗口，加一个伴随的标题与边框浮层 | 原生 Win32 窗口 + DWM 缩略图 + Direct2D/DirectWrite | DWM 缩略图只能注册到顶层窗口上；窗口数量多，要轻；手势与吸附由 Core 计算 |
| B 浮窗层 | 预警浮窗、翻译浮窗 | Slint 无边框置顶窗口，创建后给窗口句柄补上不抢焦点与工具窗口的扩展样式 | 内容是可滚动的文字列表，自绘成本高；Slint 的列表、换行、滚动现成可用 |
| C 设置层 | 设置窗口、更新窗口、问题报告窗口、首次运行向导 | Slint（fluent 样式）+ DWM 属性（Mica、圆角、暗色标题栏） | 见 2.3 节 |
| 托盘 | 托盘图标与菜单 | `Shell_NotifyIconW` + 系统弹出菜单（暗色模式下跟随系统） | 托盘本来就要一个消息窗口；菜单用系统的，行为最符合预期 |

B 层如果在 M6 实测发现 Slint 窗口补样式后仍会抢焦点或闪烁，退回 A 层的做法（Direct2D 自绘）。Core 的 `OverlayPlanner` 与 `IntelPresenter`、`TranslationPresenter` 输出的是与界面无关的内容模型，换实现不影响逻辑。

### 2.3 设置层的界面方案对比

| 方案 | 观感 | 体积与内存 | 能否在 Linux 或 Mac 上预览 | 现状与风险（2026 年 11 月） | 结论 |
| --- | --- | --- | --- | --- | --- |
| Rust 直接调 WinUI 3（windows-rs 手写） | 真 WinUI 3 | 小，但要装 Windows App SDK 运行时 | 不能 | 没有 XAML 编译器，界面全靠代码拼，数据绑定与资源字典要手写，没有成规模的先例 | 不选 |
| windows-reactor（微软在 windows-rs 仓库里的新库） | 真 WinUI 3 控件 | exe 约 3 MB；要求用户机器装有 Windows App SDK 运行时 2.0.1 以上 | 不能 | 2026 年 5 月才合入主干，类 React 的声明式写法，55 个以上控件。发布不到半年，讨论区仍有「Class not registered」一类启动问题；动画、脱离响应式层使用控件等需求未答复；便携 zip 没法保证运行时已安装 | 现在不选，列为观察项（9.2 节 Q3） |
| Rust 核心 + C# WinUI 3 外壳（csbindgen 或 uniffi） | 最好，真 WinUI 3 | 自包含约 40～80 MB，常驻 80 MB 以上 | 不能 | 两种语言、两套构建、一层 FFI；界面状态与 Core 状态隔着边界同步；云端无法构建外壳 | 不选 |
| Slint（fluent 样式） | 接近 Win11：控件按 Fluent 2 画，自动跟随明暗；不是系统控件，细节有差别 | 整个应用约 8～15 MB，常驻约 30～50 MB（设置窗口打开时） | 能。同一份 `.slint` 在三个系统上都能运行与截图 | 1.17（2026 年 6 月）；1.16 起 fluent 是所有平台的默认样式；有实时预览与给 AI 助手用的 MCP 服务；GPLv3 许可与本项目的 GPL-3.0-or-later 相容。Mica 没有内置开关，要自己取窗口句柄调 DWM | 选它 |
| Tauri + WebView2 | 可以做得很好（Fluent UI Web Components），Mica 有现成插件 | exe 小，但每个窗口带起 WebView2 进程组，约 100～200 MB | 能（浏览器里预览） | 成熟。多一种语言与一套前端构建；Win10 上 WebView2 运行时不保证存在 | 备选 |
| egui | 即时模式，自成一派，不像系统应用 | 小 | 能 | 成熟，但做不出 Fluent 观感 | 不选 |
| iced | 自定主题，要自己画一套 Fluent | 小 | 能 | 仍在 0.x，接口变动多 | 不选 |

结论：设置层与浮窗层用 Slint。

1. 它是候选里唯一同时满足「单文件、内存小、Rust 内直接调用、能在 Linux 与 Mac 上预览」的方案。用户可以在自己的 Mac 上运行设置窗口看效果，云端可以渲染截图做回归，这直接减少了 Windows 上的手工验证量。
2. 它的弱点是观感不是真 WinUI 3。所以 M4 先交付一版设置窗口的视觉原型给用户看，不满意就在投入全部页面之前换 Tauri（9.2 节 Q2）。
3. 界面只通过 `SettingsViewModel`（纯 Rust 结构，对应 macOS 的同名类型）与应用交互。以后 windows-reactor 成熟了，可以只换这一层。

### 2.4 Fluent 观感的具体实现

| 效果 | Win11 22H2 及以上 | Win11 21H2 | Win10 22H2 |
| --- | --- | --- | --- |
| Mica 背景（设置窗口） | `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE = 38, DWMSBT_MAINWINDOW = 2)`，再用 `DwmExtendFrameIntoClientArea` 把边距设为 -1；Slint 根窗口的 `background` 设为透明，侧栏与内容区各画一层半透明底色 | 不用，纯色 | 不用，纯色 |
| 纯色降级 | 用户关闭系统透明效果或开启省电时系统自动退回 | 暗色 `#202020`、亮色 `#F3F3F3`（Fluent 的 SolidBackgroundFillColorBase） | 同左 |
| 暗色标题栏 | `DWMWA_USE_IMMERSIVE_DARK_MODE = 20` | 同左 | 同左（build 19041 以上） |
| 窗口圆角 | 系统默认；弹出窗口用 `DWMWA_WINDOW_CORNER_PREFERENCE = 33` 设 `DWMWCP_ROUND` 或 `DWMWCP_ROUNDSMALL` | 同左 | 没有，窗口是直角。控件自身的圆角由 Slint 画，不受影响 |
| 明暗切换 | Slint 的 `Palette.color-scheme` 跟随系统；原生窗口监听 `WM_SETTINGCHANGE`（`ImmersiveColorSet`），读 `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` | 同左 | 同左 |
| 强调色 | WinRT 的 `UISettings.GetColorValue(Accent)`，传给 Slint 的调色板 | 同左 | 同左 |
| 预警与翻译浮窗的背景 | 半透明纯色（逐像素透明），不用 Acrylic | 同左 | 同左 |
| 缩略图圆角 | `DWMWCP_ROUNDSMALL` | 同左 | 直角 |
| 字体 | 界面用 Segoe UI Variable，中日韩文字由 Slint 的字体回退取系统字体（微软雅黑、Yu Gothic、Malgun Gothic） | 同左 | Segoe UI |
| DPI | 清单声明 `PerMonitorV2`；Slint 窗口由 winit 处理 `WM_DPICHANGED`；原生窗口见 4.6 节 | 同左 | 同左 |

浮窗不用 Acrylic 的原因：DWM 的系统背景材质在窗口非激活时会退回纯色，而浮窗设了不抢焦点，永远是非激活状态。半透明纯色在三个系统版本上表现一致，也与 macOS 版浮窗的外观接近。

托盘菜单的暗色模式没有公开接口，通行做法是调 `uxtheme.dll` 的序号导出（135 号 `SetPreferredAppMode`）。它是未公开接口，调用失败时菜单保持亮色，不影响功能。

## 3 总体架构

### 3.1 crate 划分

```text
windows/
├── Cargo.toml                 工作区
├── VERSION                    Windows 版的版本号，独立于 macOS
├── crates/
│   ├── eveo-core/             纯逻辑，对应 EVEOPreviewCore。不依赖 windows crate
│   ├── eveo-app-core/         协调器状态机（事件 → 状态 → 效果），不依赖 windows crate
│   ├── eveo-l10n/             界面文字（8 种语言），由 shared/l10n 生成
│   ├── eveo-ui/               Slint 界面与视图模型，对应 App 的 Settings、Overlays。三个系统都能编译
│   ├── eveo-platform-win/     Win32 实现，对应 EVEOPreviewPlatform。整个 crate 带 cfg(windows)
│   ├── eveo-platform-fake/    假平台：虚构的客户端与事件，用于演示模式与界面测试
│   ├── eveo-app/              可执行文件 EVE-O Preview.exe，装配各层
│   ├── eveo-probe/            命令行探针，对应 EVEOProbe，不进发布包
│   └── eveo-fake-client/      假的 EVE 客户端窗口（进程名与标题可配），只用于 CI 集成测试
└── xtask/                     打包、生成清单与图标资源、发布契约检查
```

| crate | 对应 macOS | 职责 | 约束 |
| --- | --- | --- | --- |
| `eveo-core` | `EVEOPreviewCore` | 数据模型、配置读写与迁移、标题解析、客户端登记、布局与吸附、循环、热键解析与规划、可见性规则、缩略图规划器、战斗日志与聊天日志解析、预警、翻译规则与请求拼装、更新规则、诊断规则、平台协议（trait，只含值类型） | 只依赖 serde、serde_json 等纯 Rust 库；不做文件与网络读写以外的系统调用；Linux 上测试全过 |
| `eveo-app-core` | `AppCoordinator` 的状态部分 | 接收事件、更新状态、调用规划器、产出效果清单 | 不调用任何平台接口，可以在测试里用事件序列回放 |
| `eveo-l10n` | `Localization/` | 各域的文字 trait 与 8 种语言的实现，按语言取实现的函数 | 生成的代码，改 `shared/l10n/` 的 TOML 后重新生成；只依赖 `eveo-core` |
| `eveo-ui` | `Settings/`、`Chat/`、`Updates/` 的视图 | `.slint` 文件、视图模型；文字的 Slint 全局与填值函数（生成的） | 不依赖 `eveo-platform-win` |
| `eveo-platform-win` | `EVEOPreviewPlatform` | 窗口枚举、DWM 缩略图窗口、激活、热键、鼠标钩子、前台跟踪、托盘、日志跟踪、凭据、更新安装、DPI | 实现 `eveo-core` 的 trait；unsafe 只出现在这里 |
| `eveo-app` | `EVEOPreview` | 进程入口、单实例、消息循环、效果执行 | 非 Windows 平台上链接假平台，得到演示模式 |
| `eveo-probe` | `EVEOProbe` | 在真实客户端上逐项验证平台层，输出事实报告 | 见 8.3 节 |

macOS 的协调器在 App 里，没有单元测试。Windows 版把协调器的状态机单独拆成 `eveo-app-core`，原因是我们没有 Windows 机器，能在 Linux 上测的逻辑越多越好。

第三方依赖控制在少数几个：`windows`、`slint`、`serde`/`serde_json`、`reqwest`（用系统的 TLS 与系统代理）、`tokio`（只开单线程运行时）、`ed25519-dalek`、`sha2`、`zip`。用 `cargo deny` 核对许可证都与 GPL-3.0-or-later 相容。

### 3.2 线程模型

| 线程 | 运行的东西 | 说明 |
| --- | --- | --- |
| 主线程 | Slint 的事件循环（底层是 winit 的 Win32 消息循环）、全部原生窗口的窗口过程、`RegisterHotKey`、`SetWinEventHook` 的回调、托盘、协调器状态、规划器 | 同一线程上的原生窗口消息由 winit 的循环一并分发。所有状态只在这里改，没有锁 |
| 鼠标钩子线程 | `WH_MOUSE_LL` 与它自己的消息循环 | 回调里只查一张用锁保护的绑定表，命中后 `PostMessageW` 到主线程。回调要在系统规定的时限内返回，否则钩子会被系统悄悄摘掉 |
| 日志线程 | 战斗日志与聊天日志的轮询读取、分帧、解码 | 对应 macOS 的 `CombatLogTailer` 串行队列。解析出的事件发到主线程 |
| 网络线程 | 单线程 tokio 运行时：ESI 人名查询、翻译请求、更新检查与下载、哈希 | 结果发回主线程 |
| 文件日志 | 用锁保护的写入器，任意线程可写 | 对应 macOS 的 `FileLogSink` |

其他线程给主线程发消息统一用 `slint::invoke_from_event_loop`（内部是往主线程投一条消息），不直接碰状态。

风险：winit 的消息循环与自建窗口、`WM_HOTKEY` 共存是常规用法，但没有在本项目的组合下验证过。M3 的探针先验证；不成立时改成原生窗口自己跑主循环，Slint 窗口放到单独的界面线程。

### 3.3 数据流

与 macOS 相同：任何事件只更新状态，然后请求一次重算。

```text
事件（窗口事件、前台变化、轮询兜底、配置变化、悬停、定时唤醒、受击、日志消息、热键）
   → eveo-app-core::Coordinator::handle(event) 更新状态
   → eveo-core::ThumbnailPlanner::plan(input)（纯函数）
   → Vec<Effect>
        ├── 呈现差异     → ThumbnailWindowManager：建窗口、销毁、移动、改 DWM 属性、重画浮层
        ├── 热键差异     → HotkeyService：注册与注销
        ├── 待保存的布局 → ConfigStore：延迟合并后写 config.json
        ├── 浮窗内容     → eveo-ui：更新预警与翻译浮窗的模型
        └── 下次唤醒时刻 → 一个定时器（隐藏延迟、提醒到期）
```

与 macOS 的差别：没有捕获流要协调（DWM 缩略图注册后由系统合成），所以没有 `CaptureService.reconcile` 这一支。

## 4 Windows 平台关键设计

### 4.1 客户端窗口发现

| 项 | 设计 |
| --- | --- |
| 判定条件 | 顶层可见窗口，所属进程的映像名是 `exefile.exe`（不分大小写），窗口类名是 `trinityWindow`（待实测 W1）。进程名与类名做成参数，为以后预览其他应用留扩展点 |
| 取进程名 | `GetWindowThreadProcessId` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` → `QueryFullProcessImageNameW`。这个权限对管理员权限的进程也能拿到 |
| 标题 | `EVE - <角色名>` 是已登录，`EVE` 是登录界面。用 `InternalGetWindowText`，它不给对方进程发消息，客户端卡住时也不会阻塞。解析沿用 Core 的 `TitleParser` |
| 主窗口选择 | 同一进程有多个候选窗口时用 Core 的 `ClientWindowSelector`（先看标题，再看尺寸） |
| 运行时身份 | `HWND` 加 PID 加进程创建时间（`GetProcessTimes`）。`HWND` 的值会被系统复用，只比较句柄不够 |
| 持久化身份 | 角色名，与 macOS 一致 |
| 事件 | `SetWinEventHook`（进程外回调，`WINEVENT_OUTOFCONTEXT`）监听 `EVENT_OBJECT_SHOW`、`EVENT_OBJECT_DESTROY`、`EVENT_OBJECT_NAMECHANGE`、`EVENT_SYSTEM_MINIMIZESTART`、`EVENT_SYSTEM_MINIMIZEEND`、`EVENT_SYSTEM_FOREGROUND`、`EVENT_OBJECT_LOCATIONCHANGE`。回调里先按 `idObject == OBJID_WINDOW` 过滤，只把顶层窗口的事件交给协调器 |
| 兜底轮询 | 每 `pollIntervalMs`（默认 1000 毫秒）用 `EnumWindows` 全量核对一次。事件可能丢，轮询保证最终一致 |
| 管理员权限的客户端 | 用 `OpenProcessToken` 与 `TokenElevation` 判断。客户端以管理员运行而本工具不是时，系统不允许我们激活它，钩子也收不到它前台时的输入。检测到后在「环境检查」页与托盘提示，建议两者用相同的权限运行 |
| 晨曦服（国服）客户端 | 进程名与标题格式应当相同（待实测 W2）；不同时在参数里加一组 |

### 4.2 DWM 缩略图窗口

每个客户端有两个窗口：缩略图窗口，和它拥有的一个浮层窗口。

| 项 | 设计 |
| --- | --- |
| 缩略图窗口样式 | `WS_POPUP`，扩展样式 `WS_EX_TOOLWINDOW`（不进任务栏与 Alt+Tab）、`WS_EX_NOACTIVATE`（点击不抢焦点）、按设置加 `WS_EX_TOPMOST`。`WM_MOUSEACTIVATE` 返回 `MA_NOACTIVATE` |
| 注册 | `DwmRegisterThumbnail(本窗口, 客户端窗口)`，得到句柄后用 `DwmUpdateThumbnailProperties` 设目标矩形、可见性、透明度（`opacity`）、`fSourceClientAreaOnly = TRUE`（只取客户区，去掉标题栏与边框） |
| 源尺寸与宽高比 | `DwmQueryThumbnailSourceSize`；锁定宽高比时交给 Core 的布局规则 |
| 边框与高亮边框 | 把目标矩形向内缩进边框的粗细，露出的窗口底色就是边框。改颜色只要重画底色，很便宜 |
| 为什么要浮层窗口 | DWM 把缩略图合成在目标窗口的内容之上，同一个窗口里画的标题会被盖住。所以标题、跳过循环标记、受击闪烁的着色画在另一个窗口上 |
| 浮层窗口 | `WS_POPUP`，由缩略图窗口拥有（保证始终在它上面）；扩展样式 `WS_EX_LAYERED`、`WS_EX_TRANSPARENT`（鼠标穿透到下面的缩略图窗口）、`WS_EX_NOACTIVATE`、`WS_EX_TOOLWINDOW`。内容用 Direct2D 与 DirectWrite 画到内存位图，再 `UpdateLayeredWindow`。只在内容变化时重画（改名、闪烁的每一帧） |
| 点击与拖动 | 缩略图窗口自己处理鼠标消息：按下时 `SetCapture`，移动量交给 Core 的手势规则区分点击、拖动与边缘缩放，吸附结果由 Core 的 `LayoutResolver` 给出，再 `SetWindowPos(..., SWP_NOACTIVATE)`。不用系统的移动循环（`HTCAPTION`），因为它不支持我们的吸附 |
| 悬停 | `TrackMouseEvent(TME_LEAVE)`；放大时改窗口矩形与目标矩形，锚点规则在 Core |
| 批量更新 | 一次重算里的多个窗口移动用 `BeginDeferWindowPos`、`DeferWindowPos`、`EndDeferWindowPos` 一起提交，避免先后闪动 |
| 源窗口失效 | 客户端退出后缩略图句柄失效，`DwmUpdateThumbnailProperties` 返回错误。收到销毁事件或调用失败时注销并关窗口 |
| 最小化的客户端 | 预期显示最小化前的最后一帧（待实测 W3）。结果决定「切换时最小化非活动客户端」能不能做 |
| 全屏模式 | EVE 的「固定窗口」与「窗口」模式下置顶的缩略图正常显示。独占全屏下置顶窗口可能不显示或引起切屏（待实测 W4）。「环境检查」页建议用固定窗口模式，这也是 CCP 给多开玩家的建议 |
| 透明度 | 用缩略图属性里的 `opacity`，窗口本身不设分层样式 |

不用 Windows.Graphics.Capture 的原因：它要把每帧拷到我们的纹理再画，多一份 GPU 开销；Win10 上被捕获的窗口还会有一圈黄色边框。DWM 缩略图由系统直接合成，对帧率没有影响。

### 4.3 窗口激活

系统限制：只有满足特定条件的进程才能把别的窗口设为前台，否则 `SetForegroundWindow` 只会让任务栏按钮闪烁。按触发方式分情况处理。

| 触发方式 | 是否本来就被允许 | 做法 |
| --- | --- | --- |
| 点击缩略图 | 是。我们的进程刚收到输入事件 | 直接 `SetForegroundWindow` |
| 键盘热键（`WM_HOTKEY`） | 是。系统给处理热键的进程前台权限 | 直接 `SetForegroundWindow` |
| 鼠标侧键（低级钩子） | 否 | 走下面的升级步骤 |
| 托盘菜单 | 是 | 直接 `SetForegroundWindow` |

激活步骤由 Core 的规则给出顺序，平台层逐步执行并在每步之后核对 `GetForegroundWindow`：

1. 窗口已最小化（`IsIconic`）时先 `ShowWindowAsync(SW_RESTORE)`。用异步版本，客户端卡住时不阻塞我们。
2. `SetForegroundWindow(目标)`。
3. 没成功时，用 `SendInput` 发一次不会产生任何效果的按键（按下并抬起一个未分配的虚拟键），让系统认为我们的进程刚收到输入，再调一次 `SetForegroundWindow`。不用 Alt 键，Alt 会让游戏窗口进入菜单状态。
4. 仍没成功时，`AttachThreadInput` 把我们的线程挂到当前前台线程，调 `BringWindowToTop` 与 `SetForegroundWindow`，随即解除。前台窗口卡死（`IsHungAppWindow`）时跳过这一步，避免被拖住。
5. 都失败时记一条日志，并让缩略图闪一下提示。连续失败且目标进程是管理员权限时，提示见 4.1 节。

最小化用 `ShowWindowAsync(SW_MINIMIZE)`。激活的全部调用都在主线程，单步都不等待对方进程。

### 4.4 全局热键与鼠标按键

| 项 | 设计 |
| --- | --- |
| 键盘热键 | `RegisterHotKey`，带 `MOD_NOREPEAT`，绑定到主线程的一个隐藏消息窗口。不装键盘钩子 |
| 冲突 | 返回 `ERROR_HOTKEY_ALREADY_REGISTERED` 时在设置页的该条热键旁边标出冲突。系统保留的组合（如 Win+L、Ctrl+Alt+Del、F12）由 Core 的名单提前拦截，做法同 macOS |
| 作用范围 `game` | 前台是 EVE 时注册，前台离开 EVE 时注销。这样在别的应用里这些键不会被我们吃掉。前台变化来自 4.5 节，注册与注销的差异由 Core 的 `HotkeyPlanner` 计算 |
| 作用范围 `global` | 一直注册 |
| 键名与虚拟键码 | 配置里是 `ctrl+shift+F13` 这样的字符串。Windows 的 `KeyCodeTable` 把键名映射到 `VK_*`。修饰键见 5.5 节 |
| 鼠标中键与侧键 | `WH_MOUSE_LL`，装在专用线程。只看中键与两个侧键（`XBUTTON1`、`XBUTTON2`）的按下与松开；按下命中绑定且作用范围满足时吞掉事件（返回 1）并通知主线程，它对应的松开也吞掉，否则原样放行。判断由 Core 的 `MouseHotkeyMatcher` 做，与 macOS 共用 `shared/fixtures/hotkey` 的用例 |
| 钩子被摘掉 | 回调超时后系统会不加通知地摘掉钩子。回调里不做任何耗时操作；另外每 30 秒重装一次钩子（先装新的再卸旧的） |
| 修饰键状态 | 鼠标热键带修饰键时，在回调里用 `GetAsyncKeyState` 读 Ctrl、Shift、Alt |
| 没有鼠标绑定时 | 不装钩子，线程不启动 |

### 4.5 前台跟踪

`EVENT_SYSTEM_FOREGROUND` 给出新的前台窗口。协调器据此更新「活动客户端」与「前台是不是 EVE」，驱动高亮边框、可见性规则与 `game` 范围的热键。这个事件偶尔会漏（例如从全屏应用切回），所以每次兜底轮询也读一次 `GetForegroundWindow` 核对。我们自己的窗口（缩略图、浮窗、设置窗口）成为前台时的处理沿用 Core 现有的规则。

### 4.6 DPI 与多显示器坐标

| 项 | 设计 |
| --- | --- |
| DPI 感知 | 清单里声明 `PerMonitorV2`，不在代码里调用设置函数 |
| Core 的坐标 | 全局屏幕坐标，原点在主显示器左上角，y 向下，单位是物理像素。副显示器在左边或上边时坐标为负。它与 `GetWindowRect`、`SetWindowPos`、DWM 的目标矩形一致，平台层不做换算 |
| 与 macOS 的差别 | macOS 的 Core 用点，Windows 的位置用物理像素。键名相同（`x`、`y`、`width`、`height`），位置的单位不同，所以布局不能跨平台搬（5.5 节） |
| 随 DPI 缩放的量 | 标题字号、边框粗细、吸附距离、拖动判定阈值按窗口所在显示器的 `GetDpiForWindow / 96` 放大。配置里的尺寸（缩略图宽高、默认、最小与最大尺寸）是逻辑单位，相当于 macOS 的点：Core 按缩略图所在显示器的 `ScreenInfo.size_scale`（DPI ÷ 96）换成像素，保存时换回。这样缩略图在 150% 的显示器上与 100% 的显示器上看起来一样大，标题占的比例也一样（2026-11 真机测试后改定；原设计宽高不缩放，结果在高 DPI 屏上缩略图显小而标题照常放大）。只移动不改尺寸时不改记录的宽高，拖到另一块显示器后按那块的缩放显示 |
| 显示器信息 | `EnumDisplayMonitors` 加 `GetMonitorInfoW` 取每个显示器的范围与工作区（去掉任务栏），交给 Core 做屏幕边缘吸附与越界校正 |
| 显示器变化 | 收到 `WM_DISPLAYCHANGE` 或 `WM_DPICHANGED` 后重新取显示器信息并重算。落在所有显示器之外的缩略图由 Core 的规则拉回最近的工作区 |

### 4.7 托盘图标

- 用 `Shell_NotifyIconW`（`NIF_GUID` 固定一个 GUID，图标位置不随路径变化），消息发到主线程的隐藏消息窗口。
- 监听 `TaskbarCreated` 注册消息，资源管理器重启后重新添加图标。
- 左键单击打开设置窗口，右键弹出菜单。菜单内容与 macOS 的菜单栏菜单相同，由同一份文案生成。
- 图标提供 16、20、24、32 像素几档，按任务栏所在显示器的 DPI 选。

### 4.8 日志目录与文件监视

| 项 | 设计 |
| --- | --- |
| 目录 | `SHGetKnownFolderPath(FOLDERID_Documents)` 下的 `EVE\logs\Gamelogs` 与 `EVE\logs\Chatlogs`。不拼 `%USERPROFILE%\Documents`：文档文件夹可能被重定向到 OneDrive 或别的盘。配置里的 `eveLogDirectory` 可以覆盖 |
| 编码 | 战斗日志是 UTF-8；聊天日志是带 BOM 的 UTF-16 小端，每条消息行以 U+FEFF 开头。解码与分帧在 Core（`LogLineFramer`、`ChatLogParser`），与 macOS 用同一批样本测试 |
| 打开方式 | `CreateFileW` 带 `FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE`，不妨碍游戏写入与轮换 |
| 发现追加的内容 | 轮询。对正在跟踪的文件每 250～500 毫秒读一次到文件末尾；每 2～5 秒扫一次目录找新文件。不依赖 `ReadDirectoryChangesW`：另一个进程持续追加时，目录变化通知要等到它刷新文件元数据才发出，可能晚几秒到几十秒 |
| 选文件 | 按文件名里的时间与文件头里的角色（Listener）匹配，规则在 Core 的 `CombatLogCatalog`、`ChatLogDirectory` |
| 权限 | Windows 上读文档文件夹不需要授权。Defender 的「受控文件夹访问」只拦写入，不拦读取 |

### 4.9 密钥存储

用 Windows 凭据管理器：`CredWriteW`、`CredReadW`、`CredDeleteW`，类型 `CRED_TYPE_GENERIC`，持久性 `CRED_PERSIST_LOCAL_MACHINE`，目标名 `EVE-O Preview/translation/<服务标识>`。它底层用 DPAPI 按当前用户加密，用户可以在控制面板里查看与删除。它实现 Core 的 `SecretStore` 协议，对应 macOS 的 `KeychainSecretStore`。密钥不写进 `config.json`，也不进问题报告。

不直接用 DPAPI 加密后存文件的原因：要自己管文件与删除，没有额外的好处。

### 4.10 单实例、开机启动与数据位置

| 项 | 设计 |
| --- | --- |
| 单实例 | 启动时建命名互斥量 `Local\EVE-O-Preview-<固定 GUID>`。已存在时用 `FindWindowW` 找到第一个实例的消息窗口，发一条注册消息让它打开设置窗口，然后退出 |
| 开机启动 | 写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下的一个值，命令行带 `--background`。不需要管理员权限。用户在任务管理器里禁用启动项时，设置页显示为「被系统禁用」 |
| 配置 | `%APPDATA%\EVE-O Preview\config.json`、`state.json`、`session.json`，含义与 macOS 相同 |
| 日志与缓存 | `%LOCALAPPDATA%\EVE-O Preview\logs\`、`cache\`（译文缓存、人名缓存） |
| 崩溃检测 | 沿用会话标记的做法（`session.json`）。Rust 的 panic 用钩子写进文件日志 |

### 4.11 网络

`reqwest` 用系统的 TLS（Schannel）与系统证书库，默认读取系统代理设置。不少用户访问模型服务要走代理，这一点要在 M6 验证。ESI 的请求头、翻译请求的拼装、错误分类都在 Core（`ESINameWire`、`TranslationWire`），与 macOS 共用测试用例。

## 5 与 macOS 的共享策略

### 5.1 `shared/` 的内容

| 目录 | 内容 | 格式 | 两端怎么用 |
| --- | --- | --- | --- |
| `shared/l10n/` | 8 种语言的界面文案 | TOML，见 5.2 节 | 生成 Swift 与 Rust 代码，生成结果提交进仓库 |
| `shared/static/` | 星图与物品数据 `eve-static.json`（现在在 `packaging/`）及生成脚本 `build-sde-data.py` | JSON，自带 `format` 版本字段 | macOS 打进应用包；Windows 用 `include_bytes!` 嵌进 exe |
| `shared/lexicon/` | 情报用语、舰船缩写、虚词、聊天缩写表（现在写在 `IntelLexicon.swift` 等文件里） | TOML | 同文案，生成两端代码 |
| `shared/providers/` | 翻译服务预设、提示词模板 | TOML | 同上 |
| `shared/schema/` | `config.json`、`state.json` 的 JSON Schema 与字段说明 | JSON Schema | 两端的测试用它校验各自写出的配置 |
| `shared/fixtures/` | 跨平台测试用例，见 5.4 节 | JSON 与原始样本文件 | 两端的测试各自读取 |
| `shared/FEATURES.md` | 功能清单与两端的实现状态 | Markdown | 人读；README 的功能表以它为准 |
| `shared/tools/` | `gen_l10n.py` 等生成脚本 | Python 3，只用标准库 | CI 与本地运行 |

更新日志不放 `shared/`：两端的版本号独立，发布说明各写各的，放在 `docs/release-notes/macos/` 与 `docs/release-notes/windows/`。格式（8 个语言区块）与校验脚本共用。

### 5.2 文案的共享格式

现状：每个域一个 Swift 协议，每种语言一个结构体实现；带参数的文案是函数，各语言自己拼接；漏了一条就编译不过。共约 500 条，8 种语言。

| 候选 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| JSON | 两端都能直接读 | 没有注释，多行文字难写；现有协议里每条文案的用途说明没处放 | 不选 |
| Fluent `.ftl` | 标准格式，复数与选择器强，Rust 有成熟的库 | Swift 没有官方实现；要保留「漏一条就编译不过」就得把 Fluent 的模式编译成 Swift 代码，生成器复杂；CI 要多装一个解析库 | 不选 |
| TOML + 代码生成 | 有注释与多行字符串；Python 3.11 的标准库能读；格式简单，一个生成器同时出两端代码 | 复数等语法要自己约定 | 选它 |

约定（完整说明见 `shared/tools/gen_l10n.py` 开头的注释）：

```toml
# shared/l10n/keys/update.toml —— 键的定义，只有一份
swift_file = "UpdateStrings"          # 生成的 Swift 文件名
notes = """更新域的文字……"""          # 域的说明，写进生成文件的开头

[protocols.UpdateStrings]
doc = "更新域的全部文字。"
accessor = "updates"                  # L10n 上的访问器名

[UpdateStrings.statusReady]
doc = "新版本已下载，退出时安装；参数是版本号。"
params = ["_ version: String"]        # Swift 的参数写法：外部标签、内部名、类型
# 一组的第一条可写 section = "…"，生成为 MARK
```

```toml
# shared/l10n/zh/update.toml —— 每种语言一份
[UpdateStrings]
statusReady = "新版本 {version} 已下载，将在没有 EVE 客户端运行时或退出时安装。"

# 按数量变化的文案：keys 里写 plural = "count"，值写成该语言复数类别的表
clientCount = { one = "{count} client", other = "{count} clients" }   # en
clientCount = "{count} 个客户端"                                       # zh：只有一种形式时直接写字符串

# 按参数取值分支：keys 里写 select = "<参数>"；字符串参数分 empty / other，可选值分 none / some，枚举写 cases
```

占位符可带格式：`{value:secs}`（秒数，整数不带小数点）、`{fps:.0f}`、`{items:list}` 等，全部格式见生成器。字面的花括号写 `{{` 与 `}}`。

两端用词不同时的平台变体（`macos = …`、`windows = …`）等到 Windows 接入时再加。

生成与校验：

1. `shared/tools/gen_l10n.py` 读全部 TOML，先校验：每种语言每个键都有、没有多余的键、占位符都是参数、格式适用于参数的类型、复数类别与分支的取值齐全。任一项不满足就失败，列出全部问题。
2. 生成 Swift（`macos/Sources/EVEOPreview/Localization/Generated/`）：每个域的协议与 `L10n` 上的访问器，每种语言每个协议一个结构体，以及复数规则 `L10nPlural`。形状与原先手写的一致，调用处不用改。生成的文件开头有 `@generated` 标记，质量门禁不查。
3. 生成 Rust（`windows/crates/eveo-l10n/src/generated/`）：每个域一个 trait 与各语言的单元结构体，按语言取实现的函数与 macOS 的访问器同名。不用 Slint 自带的 gettext 机制（保持两端同一个来源），而是给设置窗口用到的协议（keys 里写 `slint = true`）各生成一个 Slint 全局（`eveo-ui/ui/generated/l10n.slint`，如 `SettingsText`）：无参数的文字是属性，带参数的是纯回调；`eveo_ui::l10n::apply` 按界面语言填值，语言变了再调一次，界面立即换语言。
   - 只在一端用的文案在 keys 里写 `platforms = ["macos"]` 或 `["windows"]`；两端用词不同时值写成 `{ macos = "…", windows = "…" }`（如「访达」与「资源管理器」）。
4. 生成结果提交进仓库。CI 运行 `gen_l10n.py --check`，生成结果过期或生成目录里有多余的文件时失败。这样 `swift build` 与 `cargo build` 都不依赖 Python。

macOS 侧的迁移已在 M5 完成：一次性脚本把手写的结构体转成 TOML（467 条 × 8 种语言）；生成的结构体先用另一个类型名，与旧实现并存，临时测试对每种语言的每个键用一组固定参数调用新旧两个实现，结果逐字相同（Mac 上 11 组全部通过）；之后删掉了旧文件与临时测试，换回原来的类型名。各域共用的补充逻辑（`TranslationStrings+Status.swift`、`UpdateStrings+Format.swift`、`OverlayStrings+BuiltIn.swift`）仍是手写的协议扩展。

### 5.3 静态数据与词表

- `eve-static.json`（约 755 KB）两端共用同一个文件。Windows 嵌入 exe，同时保留 macOS 现有的「外部文件覆盖内置数据」的规则（`StaticDataFile`）。
- `IntelLexicon.swift` 里的词表由人维护、随代码审查。抽到 `shared/lexicon/` 后仍然随代码审查，两端各生成常量表。词表变了而一端没重新生成时，CI 的漂移检查会失败。

### 5.4 跨平台测试用例

macOS 的样本现在是 Swift 代码拼出来的（如 `ChatLogFixtures.swift`）。抽成文件后两端读同一份。

```text
shared/fixtures/
├── chatlog/          原始 .txt（UTF-16LE 带 BOM，二进制原样保存）+ 同名 .expected.json
├── combatlog/        原始 .txt（UTF-8）+ .expected.json
├── intel/            输入消息 + 期望的分段、星系、舰船、人数
├── title/            窗口标题 → 期望的身份
├── hotkey/           热键字符串 → 期望的解析结果与规范写法
├── config/           各版本的配置文件 → 迁移并校验后的期望输出
├── layout/           吸附与缩放的输入 → 期望矩形
├── cycle/            循环组的事件序列 → 期望的目标
├── update/           Release 列表 JSON → 期望选中的版本、发布说明区块、校验和
├── translation/      消息 + 设置 → 期望的请求体与提示词
└── semver/           版本字符串 → 解析与比较结果
```

规则：

1. 每个用例是「输入 + 期望输出」的数据，不含任何语言的代码。期望输出的 JSON 结构在用例目录的 `README.md` 里写明。
2. 样本里的角色名、频道名都是虚构的，星系名用公开数据，与现有约定一致。
3. `.gitattributes` 把 `shared/fixtures/**/*.txt` 标为二进制，防止换行符与编码被改。
4. 两端各有一个「一致性测试」目标：遍历目录，逐个断言。一端新增解析规则时先加用例，另一端的 CI 立刻变红，漂移在合并前暴露。CI 的路径触发保证改 `shared/` 时两端都跑（7.3 节）。
5. 现有的约 645 个 Swift 测试不删。其中表驱动的部分逐步改成读共享用例；与 Swift 类型细节绑定的测试留在原地，Rust 侧对译一份。

### 5.5 配置文件

| 问题 | 结论 |
| --- | --- |
| 格式是否统一 | 统一。同一份 JSON Schema，同一个 `schemaVersion` 序列，键名与默认值相同。迁移规则两端用 `shared/fixtures/config` 对齐 |
| 平台专属的部分 | `capture`（只有 macOS 用）在 Windows 上读入后原样保留、不使用。Windows 新增的设置放在 `general.windows` 下，macOS 同样原样保留。两端都要改成「不认识的键读入后写回」，现在 macOS 是丢弃 |
| 能否直接拷贝文件 | 不建议。布局位置的单位不同（点与物理像素），显示器也不同；宽高两端都是逻辑单位 |
| 互相导入 | 做成设置里的「导入配置…」，读对方的 `config.json`，只取可移植的部分 |

导入时各部分的处理：

| 配置内容 | 处理 |
| --- | --- |
| 配置方案的名字、循环组及成员顺序、隐藏名单、高亮颜色、提醒设置、预警与翻译的频道和选项、界面语言 | 原样导入 |
| 热键 | 键名可移植。修饰键 `ctrl`、`shift` 原样；`opt` 对应 `alt`（两端的解析器都接受这两个写法，各自输出本平台的规范写法）；带 `cmd` 的绑定在 Windows 上对应 `win`，默认不导入并在结果里列出，因为 Win 组合大多被系统占用。鼠标键 `Mouse3`～`Mouse5` 两端含义一致，由 `shared/fixtures/hotkey` 固定 |
| 每角色的布局、登录位置、浮窗位置 | 不导入，用默认值 |
| `eveLogDirectory`、`capture` | 不导入 |
| 翻译服务的地址与模型名 | 导入。密钥不在配置里，要用户重新填 |

为了让导入方知道文件来自哪个平台，新版本在顶层写一个 `platform` 键（`macos` 或 `windows`）。旧版 macOS 读到它会忽略，没有这个键的文件按 macOS 处理。

### 5.6 两份 Core 的长期对策

1. 流程上「规格先行」：改解析或规则时，PR 里先改 `shared/fixtures` 与设计文档，再改两端的实现。只改一端的 PR 在另一端的一致性测试里会失败。
2. `shared/FEATURES.md` 记录每项功能在两端的状态，发版前核对。
3. 长期可以评估让 Rust 的 Core 成为唯一实现，macOS 通过 UniFFI 生成的 Swift 绑定调用它。现在不做：macOS 版稳定，只有命令行工具链，引入 Rust 静态库会让它的构建与签名变复杂。触发条件见 9.2 节 Q9。

## 6 更新与分发

### 6.1 打包形式对比

| 形式 | 优点 | 缺点 | 结论 |
| --- | --- | --- | --- |
| 便携 zip（单个 exe） | 最简单；不要管理员权限；符合上游用户的习惯；自更新只是替换一个文件 | 没有开始菜单快捷方式与卸载项（由应用自己提供创建与清理） | v1 采用 |
| Velopack | 现成的安装器、增量更新、回滚；有 Rust SDK；安装到用户目录，不要管理员权限 | 多一个更新进程与它自己的发布文件约定；它的 GitHub 源按仓库的 Release 列表找文件，与 macOS 的 Release 混在一起时要自己写源；macOS 已有一套更新策略（何时安装、发布说明怎么选），两端行为会不一致 | 备选。自写更新器出问题时换它 |
| MSI（WiX） | 企业环境熟悉 | 要管理员权限，升级逻辑繁琐，对单个 exe 是过度设计 | 不选 |
| MSIX（自己分发） | 干净的安装与卸载 | 没有受信任的证书就装不上，比 SmartScreen 更严 | 不选 |
| MSIX（微软商店） | 商店代签名，没有 SmartScreen 警告；商店负责更新；个人开发者注册现在免费 | 要过审；应用名里带 EVE 可能涉及商标问题；更新节奏受审核影响 | v1 之后作为第二渠道 |
| winget 清单 | 命令行安装，支持 zip 里的便携程序 | 只是索引，文件仍是我们的 zip | v1 之后加 |

首次运行时如果 exe 不在固定位置（例如在下载目录或压缩包的临时目录里），向导提议把它复制到 `%LOCALAPPDATA%\Programs\EVE-O Preview\` 并创建开始菜单快捷方式。用户也可以拒绝，留在原地运行。

### 6.2 发布契约（Windows）

一个 Windows Release（tag `win-v<版本>`）有固定的 4 个附件：

| 附件 | 内容 |
| --- | --- |
| `EVE-O-Preview-<版本>-windows-x64.zip` | `EVE-O Preview.exe`、`LICENSE.txt`、`README.txt` |
| `eve-o-preview-<版本>-windows-source.zip` | 该 tag 的 `windows/` 与 `shared/` 源码（GPL 要求） |
| `SHA256SUMS.txt` | 上面两个文件的 SHA-256 |
| `SHA256SUMS.txt.sig` | 对 `SHA256SUMS.txt` 的 ed25519 签名 |

exe 的版本资源里写入版本号、构建标签与提交号。CI 在发布前核对这份契约，做法与 macOS 的「检查产物」一步相同。

### 6.3 自动更新

规则（多久检查一次、跳过的版本、何时可以安装、发布说明按语言取哪一块、中间版本的说明）全部来自 Core 的 `UpdatePolicy`、`ReleaseHistory`、`ReleaseNotes`，从 Swift 移植，与 macOS 行为一致。平台层只做下面这些：

1. 取 `https://api.github.com/repos/deletexiumu/eve-o-preview/releases?per_page=100`，只看 tag 以 `win-v` 开头、不是草稿的条目，按语义化版本取最高的正式版。不用 `/releases/latest`，它永远指向 macOS 版（7.4 节）。
   测试版的渠道：正在运行的是预发布版（`win-v0.x` 的测试版或 CI 构建）时，也提示更新的预发布版；正在运行正式版时只提示正式版。中间版本的发布说明从同一页列表里挑，不再另请求。
2. 附件地址必须在本仓库的 `/releases/` 路径下，校验规则移植 `UpdateFeed.accepts`。
3. 下载 zip、`SHA256SUMS.txt` 与 `.sig`。先用内置的 ed25519 公钥验签校验和文件，再核对 zip 的 SHA-256。签名文件是对 `SHA256SUMS.txt` 原始字节的 ed25519 签名的 base64（一行）。
4. exe 带 Authenticode 签名时，用 `WinVerifyTrust` 核对，并要求签名者与当前运行的 exe 相同。没有签名的阶段只靠第 3 步。
5. 安装：把新 exe 解到同目录的临时文件名（`*.new`）；把正在运行的 exe 改名为 `*.old`（Windows 允许给运行中的 exe 改名）；把新文件改成正式名字；在 `state.json` 的 `updates.pendingSwap` 记下新旧版本，带 `--after-update <旧进程编号>` 启动新进程并退出。新进程先等旧进程退出再做单实例检查。
   下载自己跟重定向（最多 5 次，WinHTTP 的自动重定向是关掉的）：GitHub 的附件会重定向到存放文件的主机，正式地址下只跟到 https，测试地址下只跟同源。解出 exe 后读它的版本资源（`ProductVersion` 与 `BuildLabel`，由 build.rs 写入）与 PE 头的机器类型，交给 Core 的 `validate` 核对。
6. 回滚：新版本第一次启动时在 `pendingSwap` 写下启动时刻，运行满 30 秒或正常退出时确认（写 `updates.lastInstall`、删除 `*.old`）。下次启动时启动时刻还在，说明上一次没走到确认（崩溃或被结束）：把自己改名为 `*.failed`、`*.old` 改回正式名字，启动旧版后退出，记一条 `launchFailed` 的安装记录。回滚只做一次。
7. 安装目录不可写（例如用户放在了 Program Files 下）时只提示有更新，给出下载页的链接。
8. 安装时机与 macOS 相同：没有 EVE 客户端运行满一分钟时，或用户退出时。

ed25519 私钥放在 Actions secret 里，并离线备份，做法同 macOS 的签名证书。公钥写在 `eveo-core` 里。它的作用是在没有 Authenticode 证书时也能保证更新包确实出自本项目的 CI。

### 6.4 代码签名与 SmartScreen

没有签名时的影响：

| 现象 | 说明 |
| --- | --- |
| SmartScreen 蓝色警告「Windows 已保护你的电脑」 | 用户要点「更多信息」再点「仍要运行」。每个新版本的 exe 都会重新触发，直到这个文件积累了足够的下载量 |
| 浏览器下载警告 | Edge 可能提示「不常下载」 |
| 智能应用控制（Smart App Control） | Win11 上开启时直接阻止未签名的程序，没有放行按钮。这部分用户在我们签名之前用不了 |
| 杀毒软件误报 | 未签名、装低级鼠标钩子、枚举窗口，这几项加在一起容易被启发式规则误判。可以把文件提交给微软做误报分析（免费），不能保证结果 |

签名的选项：

| 选项 | 费用级别 | 可行性 | 说明 |
| --- | --- | --- | --- |
| 不签名 | 0 | 立即可用 | 上表的全部影响 |
| SignPath Foundation | 免费 | 要申请并审核 | 面向开源项目，证书的主体是 SignPath Foundation，签名请求从 GitHub Actions 发起，要求构建过程可核对。本项目是 GPL、构建全在 CI，符合基本条件。审核时间不确定 |
| Certum 开源代码签名证书 | 每年几十欧元 | 个人可申请，不限地区 | 证书主体是「Open Source Developer, 姓名」。云端签名（SimplySign）要一次性口令，接进 CI 比较麻烦 |
| Azure Artifact Signing（原 Trusted Signing，2026 年初改名） | 每月约 10 美元（Basic 档，每月 5,000 次签名） | 受地区限制 | 据我所知个人身份验证只对美国与加拿大开放，组织对美国、加拿大、欧盟、英国开放。官网价格页没有列出资格条件，开通前要在 Azure 门户里核实。用户不在这些地区时不可用 |
| 普通 OV 证书 | 每年约 200～500 美元 | 可行 | 2023 年起私钥要放在硬件令牌或云 HSM 里。新证书也要积累信誉 |
| EV 证书 | 每年约 300～700 美元 | 可行 | 2024 年起不再立即获得 SmartScreen 信誉，不值这个价 |
| 微软商店 | 0（个人注册免费） | 要过审 | 商店代签名，绕开 SmartScreen。见 6.1 节 |

推荐：

1. M0 就申请 SignPath Foundation，审核与开发并行。
2. 测试版（`win-v0.x`）不签名发布，README 里写清楚 SmartScreen 的放行步骤，并说明更新包有 ed25519 校验。
3. `win-v1.0.0` 之前如果 SignPath 没有批下来，再在 Certum 与继续不签名之间决定（9.2 节 Q5）。
4. 一旦开始签名，签名者就不应再换。自动更新会核对签名者，换了之后老版本只能提示更新，与 macOS 换证书的后果相同。

## 7 仓库重组与改名计划

### 7.1 目标结构

```text
eve-o-preview/
├── README.md 及 7 个语言版本     两个平台的总览、下载入口、功能表
├── LICENSE
├── macos/
│   ├── Package.swift、Sources/、Tests/、VERSION
│   ├── packaging/               Info.plist、图标、证书指纹（eve-static.json 移到 shared）
│   └── scripts/                 build-app.sh、package-release.sh、make-update-test-feed.sh
├── windows/                     见 3.1 节
├── shared/                      见 5.1 节
├── docs/
│   ├── macos/                   现有的 architecture.md 等 6 份文档
│   ├── windows/                 本方案定稿后放这里
│   └── release-notes/{macos,windows}/
├── scripts/                     仓库级的 check_quality.py、check_release_notes.py
└── .github/workflows/           macos.yml、windows.yml
```

### 7.2 迁移顺序

顺序由已安装的 macOS 客户端决定。约束有两条：≤1.2.2 的客户端在改名后不能自动安装（附件地址里的新仓库名通不过白名单）；它们读 `/releases/latest` 时遇到解析不了的 tag 会报错。

| 步骤 | 做什么 | 对已安装客户端的影响 | 回滚 |
| --- | --- | --- | --- |
| 0 定名 | 确认新名字 `eve-o-preview`，并确认账号下没有同名仓库（例如上游的 fork）。名字会写进过渡版，定了就不能再改 | 无 | 无 |
| 1 过渡版 v1.3.0 | 在现在的目录结构与仓库名下发布。内容见 7.5 节 | ≤1.2.2 正常自动更新到 1.3.0 | 普通的版本回退 |
| 2 目录重组 | 一个 PR：第一个提交只做 `git mv`，第二个提交改路径引用与 CI。合并前用「演练发布」核对 macOS 的发布契约没有变化 | 无。Release 的附件名与内容不变 | 回退这个 PR |
| 3 发布 v1.3.1 | 从新目录结构发一个 macOS 版本，证明发布流程完好。可以没有功能改动 | 正常自动更新 | 删掉 Release 与 tag，修复后重发 |
| 4 Windows 开发 | 在 `windows/` 下开始，不依赖改名。测试构建只作为工作流制品，不建 Release | 无 | 无 |
| 5 等待 | v1.3.0 发布后至少等 3 周。用 1.3.0 及以后各版 dmg 的下载次数与之前版本的对比估计升级比例 | 无 | 无 |
| 6 改名 | 在 GitHub 设置里把仓库改名为 `eve-o-preview`。不与任何发版绑在同一天 | 1.3.0 及以上不受影响。≤1.2.2 仍能收到检查结果，但不能自动安装，要手动下载一次 | 把名字改回去。1.3.0 及以上两个名字都接受，来回改不受影响 |
| 7 改名后的清理 | 一个 PR 把 26 个文件里的旧仓库名换成新名字，更新地址切到新名字（仍接受旧名字），发布 macOS v1.3.2。本机的 git remote 改成新地址 | 正常自动更新 | 普通的版本回退 |
| 8 Windows 首个公开版本 | 改名之后才建第一个 `win-v*` Release，这样 Windows 客户端只需要认新名字 | 见 7.4 节 | 删掉 Release |

改名后要记住两件事：

1. 不要在账号下新建名为 `eve-o-preview-macos` 的仓库。一旦新建，GitHub 的重定向就失效，所有旧客户端的更新检查与旧链接都会断。
2. macOS 应用的 bundle id（`io.github.deletexiumu.eveopreview-macos`）、签名证书与指定要求不改。改了会让用户重新授权，自动更新的签名核对也会拒绝。

### 7.3 CI 拆分

| 工作流 | 触发 | 运行器 | 任务 |
| --- | --- | --- | --- |
| `macos.yml` | 推送 `v*` tag；手动运行。PR 的 macOS 检查改在维护者的 Mac 上跑 `scripts/verify_macos.sh`，以提交状态 `local/macos` 上报（macOS 架构文档 9.5 节） | `macos-15` | 现有的全部步骤，路径加上 `macos/` 前缀；另加共享生成物的漂移检查 |
| `windows.yml` | PR 与推送到 `main`，改动涉及 `windows/**`、`shared/**`、`scripts/**`、`docs/release-notes/windows/**` 或工作流自身；推送 `win-v*` tag；手动运行 | 见下 | 见下 |

`windows.yml` 的任务：

| 任务 | 运行器 | 内容 |
| --- | --- | --- |
| `core` | `ubuntu-latest` | 质量门禁、`cargo fmt --check`、`cargo clippy -D warnings`、`cargo deny`、`eveo-core` 与 `eveo-app-core` 的测试、一致性测试、`cargo check --target x86_64-pc-windows-msvc` 整个工作区、界面截图回归 |
| `build` | `windows-latest` | 全工作区测试、发布构建、集成探针（8.2 节）、打包、发布契约检查、上传制品与截图 |
| `release` | `ubuntu-latest` | 只在 `win-v*` tag 上运行：核对 tag 与 `windows/VERSION` 一致，签校验和，建 Release，`make_latest` 设为 `false`，随后调接口确认 `/releases/latest` 仍是 `v*` 的 tag，不是就失败并报警 |

细节：

1. 分支保护里的必需检查不能直接挂在带路径过滤的工作流上，否则没触发的工作流会让 PR 一直等待。做法是 `windows.yml` 在 PR 上总触发，第一个任务用 `git diff` 判断有没有相关改动，没有就让后续任务跳过（跳过算通过）。macOS 的本机验证脚本用同样的路径判断，没有相关改动时直接上报成功。
2. tag 推送不受路径过滤影响，靠 tag 的前缀区分两个工作流。
3. 质量门禁 `scripts/check_quality.py` 扩展为按语言配置：Rust（`//`、`///`、`//!`、块注释；函数从 `fn` 起算）与 `.slint`（`//`）加入检查，阈值不变：注释率大于 20%，单文件少于 1000 行，单函数少于 500 行。生成的文件（文案、词表）排除在外。
4. 第三方 action 钉到提交 SHA，与现有约定一致。
5. 分支名、提交信息、PR 的规则对 Windows 代码同样适用。提交的范围可以写成 `feat(windows): …`、`fix(macos): …`、`chore(shared): …`。

### 7.4 tag 规则

结论：macOS 永久用 `v*`，Windows 用 `win-v*`，Windows 的 Release 一律不标为 latest。我同意调用方的倾向，理由如下。

| 方案 | 对 ≤1.2.2 客户端 | 对以后的客户端 | 代价 |
| --- | --- | --- | --- |
| A：macOS 留 `v*`，Windows 用 `win-v*` 且不标 latest（推荐） | 更新检查一直能用，不依赖用户先升级到过渡版 | 正常 | tag 的含义不对称，要写进文档；发布时要保证 latest 不被 Windows 占用（CI 已有核对） |
| B：macOS 改成 `mac-v*`，客户端按前缀从列表里筛 | 没升级到过渡版的客户端从此每次检查都报「更新源格式错误」，而且没有补救办法 | 正常 | 多一个不可逆的断点，换来的只是命名整齐 |

补充措施，让方案 A 不依赖人不犯错：

1. 过渡版起，macOS 客户端在 `/releases/latest` 的 tag 解析失败时改为读列表、取最高的 `v*` 正式版（7.5 节）。这样即使某次 Windows Release 被误标成 latest，新客户端也不受影响。
2. Windows 的 `release` 任务在发布后核对 latest，见 7.3 节。误标时在 Releases 页面把最近的 macOS Release 重新设为 latest 即可恢复。
3. 预发布版本的 tag：macOS 沿用 `v1.4.0-beta.1`，Windows 用 `win-v0.3.0-beta.1`，带 `-` 的标为预发布。
4. Release 列表里两端的版本混在一起。macOS 客户端取中间版本说明时会跳过解析不了的 tag（现有行为），但每页 30 条里会被 Windows 版本占掉一部分。过渡版把这个请求改成每页 100 条。

### 7.5 过渡版 v1.3.0 的内容

只改更新相关的代码，尽量小：

| 改动 | 位置 |
| --- | --- |
| 附件与发布页的白名单同时接受 `/deletexiumu/eve-o-preview-macos/releases/` 与 `/deletexiumu/eve-o-preview/releases/` 两个路径前缀，其余校验不变 | `UpdateContracts.swift` 的 `isProductionAsset` |
| `/releases/latest` 的 tag 解析失败时，退到 Release 列表里取最高的 `v*` 正式版 | `ReleaseFeedParser`、`SystemUpdateService` |
| 列表请求改为每页 100 条 | `UpdateFeed.productionHistoryURL`、`ReleaseHistory.pageSize` |
| 检查地址暂时仍用旧仓库名 | 改名之前新名字的地址不存在；改名之后旧地址由 GitHub 重定向，现有的 `URLSession` 会跟随 |
| 对应的测试 | 新旧两个名字的地址各一组；latest 是 `win-v*` 时的回退 |

问题报告的链接（`IssueURLBuilder`）、ESI 的 User-Agent、README、`FakeUpdateService`、测试夹具、CI 里的旧名字在步骤 7 统一替换。在那之前它们靠重定向继续可用。

macOS 的 Release 附件名不改，包括源码包的名字 `eve-o-preview-macos-<版本>-source.*`。它是发布契约的一部分，名字里带 macos 在 monorepo 里也仍然准确（内容是 `macos/` 与 `shared/`）。

### 7.6 README 与链接

1. 根目录的 README（8 种语言）改成两个平台的总览：各自的下载链接、系统要求、安装说明、功能表。平台专属的开发说明放在 `macos/README.md` 与 `windows/README.md`。
2. macOS 的下载链接可以继续用 `/releases/latest`。Windows 的下载链接指向具体的 `releases/tag/win-v<版本>`，在发版的 PR 里与 `windows/VERSION` 一起改，CI 核对两者一致。
3. 文档之间的相对链接随 `git mv` 一起修。CI 加一个链接检查，只查仓库内的相对链接。

## 8 分阶段实施计划与验证方式

### 8.1 里程碑

| 里程碑 | 内容 | 可验证的产出 |
| --- | --- | --- |
| M0 准备 | 定名；发布 macOS 过渡版 v1.3.0；申请 SignPath Foundation；本方案定稿 | v1.3.0 的 Release；≤1.2.2 的客户端能自动更新到它 |
| M1 仓库重组 | 7.2 节的步骤 2、3；`shared/` 建好骨架并移入静态数据；质量门禁支持 Rust | macOS v1.3.1 从新结构发布成功；两个工作流按路径触发 |
| M2 Core 第一批 | Rust 工作区；移植模型、配置、标题、客户端登记、几何、布局、循环、热键、规划器、可见性；抽出对应的共享用例 | Linux 上 `cargo test` 全过；一致性测试在两端都过；`cargo check` 的 Windows 目标通过 |
| M3 平台探针 | `eveo-platform-win` 的发现、缩略图窗口、激活、热键、前台跟踪；`eveo-fake-client`；`eveo-probe` | CI 的 Windows 运行器上集成探针通过，截图作为制品上传；用户在真实客户端上跑一次探针，交回事实报告（W1～W8） |
| M4 预览可用 | `eveo-app-core` 协调器；托盘；手势、吸附、悬停放大、右键菜单；设置窗口的视觉原型与基本页面；配置持久化；单实例 | 内部测试包（工作流制品）；用户确认设置窗口的观感（Q2）；手工清单第一部分通过 |
| M5 设置完整 | 全部设置页；文案抽到 `shared/l10n` 并在两端生效；配置方案；鼠标按键热键与作用范围；Mica 与降级 | macOS 的文案双跑测试通过后切换到生成的代码；8 种语言的界面截图 |
| M6 日志功能 | 移植战斗日志、聊天日志、预警、翻译、ESI；日志跟踪；凭据管理器；预警与翻译浮窗 | 回放共享样本的端到端测试通过；手工清单第二部分通过 |
| M7 发布能力 | 更新器；诊断与问题报告；开机启动；打包与发布契约；`win-v0.9.0-beta.1` | 用本地假源完成一次真实的自更新与一次回滚；测试版 Release |
| M8 改名 | 7.2 节的步骤 5～7。时间上独立，条件满足就做，但要在 M7 建第一个 Windows Release 之前完成 | 仓库新名字生效；macOS v1.3.2 发布 |
| M9 正式版 | 修测试版的反馈；签名（如已获批）；`win-v1.0.0` | 正式 Release；README 更新 |

M2 可以与 M1 并行开始（Rust 代码先在分支上写），M8 与 M2～M6 互不阻塞。

### 8.2 不靠 Windows 机器能验证的部分

| 手段 | 在哪里跑 | 覆盖什么 |
| --- | --- | --- |
| `eveo-core`、`eveo-app-core` 的单元测试与共享用例 | Linux 容器、CI | 全部纯逻辑：解析、规则、规划、协调器的事件序列 |
| `cargo check --target x86_64-pc-windows-msvc` | Linux 容器、CI | 平台层的类型与接口用法（参数类型、结构体字段、错误处理）。发现不了运行时行为的错误 |
| 界面截图回归 | Linux 容器、CI | 用 Slint 的软件渲染器把每个设置页渲染成图片，8 种语言、明暗两套。云端可以直接看图改界面 |
| 演示模式（假平台） | 用户的 Mac、Linux | `cargo run -p eveo-app` 在非 Windows 系统上用假客户端运行：设置窗口、浮窗、托盘菜单的内容都能操作。用户在 Mac 上就能评审界面与文案 |
| 集成探针 | CI 的 `windows-latest` | 启动若干个 `eveo-fake-client`（进程名 `exefile.exe`，标题 `EVE - Test Pilot N`，客户区画固定的色块），运行探针：发现、注册缩略图、截屏核对色块出现在缩略图窗口的位置、激活并核对前台窗口、用 `SendInput` 触发热键、写假日志并核对事件。截图与报告作为制品上传 |
| 更新器的端到端测试 | CI 的 `windows-latest` | 本地起一个假源，完成下载、验签、替换、重启、回滚 |

集成探针依赖一个前提：GitHub 托管的 Windows 运行器有可交互的桌面会话且 DWM 在运行。界面自动化测试在这些运行器上普遍可用，所以预期成立，M3 一开始先验证这一点。不成立时，集成探针改为只在用户的 Windows 机器上跑，手工验证量会增加。

### 8.3 需要真实 Windows 与真实客户端的部分

目标是把用户的手工工作压到两类：跑一次探针，和按清单做一次验收。

1. 事实报告：`eveo-probe report` 一条命令收集全部待实测的事实，写成一个 JSON 文件（不含角色名以外的个人信息，角色名可选择脱敏）。用户或任何有 Windows 游戏机器的人运行后把文件交回即可。

| 编号 | 待实测的事实 |
| --- | --- |
| W1 | EVE 客户端主窗口的类名、进程名、每个进程的顶层窗口数量与尺寸 |
| W2 | 晨曦服客户端的进程名与标题格式 |
| W3 | 客户端最小化后 DWM 缩略图显示什么 |
| W4 | 窗口、固定窗口、全屏三种模式下置顶缩略图的表现 |
| W5 | 各触发方式下 `SetForegroundWindow` 的成功率，升级步骤走到第几步 |
| W6 | 战斗日志与聊天日志的实际路径、编码、追加后多久能读到 |
| W7 | winit 的消息循环与原生窗口、`WM_HOTKEY`、WinEvent 回调共存是否正常 |
| W8 | 客户端以管理员运行时哪些操作失败 |

2. 手工验收清单：仿照 `docs/manual-test-checklist.md` 写 Windows 版，分两部分（M4、M6 各一部分），每部分控制在 20 分钟以内，只列自动化覆盖不到的项：真实客户端下的切换手感、多显示器与不同缩放比例、热键在游戏内的表现、浮窗在战斗中的可读性。
3. 验证环境的选择见 9.2 节 Q7。Mac 上的 Windows 虚拟机（ARM 版 Windows 加 x64 模拟）可以跑本工具与假客户端，适合看界面与基本行为；真实的 EVE 客户端在虚拟机里不一定能正常运行，W1～W6 最终要在一台真实的 Windows 游戏机器上确认。

### 8.4 开发方式

1. 移植按模块进行，每个模块的顺序是：抽共享用例 → 对译 Swift 实现 → 对译测试 → 一致性测试通过。Swift 源码与测试是现成的规格，这部分适合 AI 批量完成。
2. 平台层每个服务先写探针子命令，再写实现，与 macOS 当时的做法一致。
3. 每个 PR 都要过 `core` 任务（Linux，几分钟内出结果），平台层的 PR 再看 `build` 任务的集成探针与截图。

## 9 风险与已定的问题

### 9.1 风险

| 编号 | 风险 | 可能性 | 影响 | 应对 |
| --- | --- | --- | --- | --- |
| R1 | 两份 Core 行为漂移，维护成本翻倍 | 高 | 高 | 共享用例与一致性测试；规格先行的流程；长期评估合并（5.6 节） |
| R2 | 平台层的运行时错误在云端发现不了，反馈周期长 | 高 | 中 | 假客户端加 CI 集成探针；探针先行；把逻辑尽量放进能在 Linux 测的 crate |
| R3 | 未签名导致 SmartScreen 警告、智能应用控制阻止、杀毒误报 | 高 | 中 | 尽早申请 SignPath；README 说明；ed25519 校验保证更新安全；之后上商店 |
| R4 | Slint 的观感达不到用户对「好看」的预期 | 中 | 中 | M4 先出视觉原型给用户确认；界面隔在视图模型之后，可换 Tauri 或 windows-reactor |
| R5 | Slint 窗口的 Mica、中日韩字体、不抢焦点的浮窗有未预见的问题 | 中 | 中 | M3、M4 各做一次小验证；Mica 不行就用纯色（Win10 的降级路径本来就要做）；浮窗不行就退回 Direct2D 自绘 |
| R6 | 改名或 tag 操作失误，macOS 的自动更新中断 | 低 | 高 | 过渡版先行并留足时间；CI 核对 latest；发布契约检查；改名可回滚 |
| R7 | `SetForegroundWindow` 在某些系统设置或客户端状态下不可靠 | 中 | 高 | 多级升级步骤；逐步核对与日志；W5 实测 |
| R8 | 低级鼠标钩子被安全软件拦截或被系统摘除 | 中 | 低 | 只在有鼠标绑定时安装；定期重装；键盘热键不受影响 |
| R9 | CI 的 Windows 运行器不能跑集成探针 | 低 | 中 | M3 最先验证；不行就把探针移到用户机器 |
| R10 | GitHub 接口限流影响 Windows 的更新检查（列表接口比 latest 响应大） | 低 | 低 | 沿用 ETag 与每天一次的频率；限流的处理规则已在 Core |
| R11 | 工作量：Core 约 1.5 万行、测试约 1.3 万行、平台与界面约 3 万行要重写 | 确定 | 高 | 分里程碑交付，M4 就有可用的预览；日志类功能（M6）可以晚于首个测试版 |
| R12 | CCP 对第三方工具的政策 | 低 | 高 | 与上游一样只做预览与窗口切换，不注入、不广播输入、不读内存；README 写明 |

### 9.2 已定的问题（原「待用户决定」，2026-11-23 全部按建议确定）

| 编号 | 问题 | 选项 | 推荐 |
| --- | --- | --- | --- |
| Q1 | 语言 | Rust；C# NativeAOT；C++ | Rust（2.1 节） |
| Q2 | 设置窗口的界面库 | Slint；Tauri + WebView2；等 windows-reactor | Slint。M4 看过视觉原型后再最终确认，不满意就换 Tauri |
| Q3 | 是否现在就用 windows-reactor | 现在用；观察；不考虑 | 观察。它发布才半年，而且要求用户机器装 Windows App SDK 运行时，与便携分发冲突。v1 之后再评估 |
| Q4 | 仓库新名字 | `eve-o-preview`；`eveo-preview`；其他 | `eve-o-preview`，前提是账号下没有同名仓库。这个名字会写进过渡版，定了不能改，请在 M0 前确认 |
| Q5 | 代码签名 | 先不签并申请 SignPath；直接买 Certum；Azure Artifact Signing | 先不签并申请 SignPath。请告知所在地区，以判断 Azure 是否可用 |
| Q6 | tag 规则 | macOS 留 `v*`、Windows 用 `win-v*`；全部改成带平台前缀 | 前者（7.4 节） |
| Q7 | Windows 验证环境 | 用户自己的 Windows 机器；Mac 上的虚拟机；找有 Windows 的玩家帮忙跑探针 | 三者结合：虚拟机看界面，真实机器跑探针与验收清单。请告知手头有没有可装 EVE 的 Windows 机器 |
| Q8 | 支持 Windows 10 吗 | 支持并降级；只支持 Windows 11 | 支持。代价只是一条纯色背景的降级路径，而仍有不少玩家在用 Windows 10 |
| Q9 | 是否把 macOS 的 Core 也换成 Rust（经 UniFFI） | 现在做；Windows v1 之后评估；不做 | Windows v1 之后评估。触发条件：一致性测试之外仍多次出现两端行为不一致，或共享用例的维护成本明显高于预期 |
| Q10 | 过渡期多长 | 2 周；3 周；看升级比例 | 至少 3 周，并且 1.3.0 以上各版 dmg 的下载量明显超过此前版本后再改名 |
| Q11 | Windows 首个公开版本的范围 | 只含预览与切换（M4 之后就发测试版）；等功能与 macOS 对齐再发 | 前者。预览与切换是替代上游的核心，早发早收到真实环境的反馈 |
| Q12 | 文案迁移到 `shared/l10n` 的时机 | Windows 开工前先迁 macOS；M5 再迁 | M5。先让 Windows 的格式与生成器在新代码上跑通，再动稳定的 macOS 代码 |
| Q13 | 是否做上游 C# 版配置的导入 | v1 做；v1 之后；不做 | v1 之后优先做。它对吸引老用户有用，但不影响核心功能 |
| Q14 | 版本号 | 两端各自独立；两端同步 | 各自独立。Windows 从 0.1.0 起，功能对齐后发 1.0.0 |

## 10 资料来源

- windows-reactor（windows-rs PR #4479，2026 年 5 月）：https://github.com/microsoft/windows-rs/pull/4479
- Windows App SDK 2.0 发行说明：https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-2-0
- Slint 1.17 发布说明：https://slint.dev/blog/slint-1.17-released
- Slint 默认样式改为 fluent（1.16）：https://slint.dev/blog/default-native-style-change
- Azure Artifact Signing 价格页：https://azure.microsoft.com/en-us/pricing/details/artifact-signing/
- Velopack 文档：https://docs.velopack.io/
- 仓库内：`docs/architecture.md`、`docs/design-v1.1.md`、`docs/design-intel-translate.md`、`Sources/EVEOPreviewCore/Contracts/UpdateContracts.swift`、`.github/workflows/build.yml`
