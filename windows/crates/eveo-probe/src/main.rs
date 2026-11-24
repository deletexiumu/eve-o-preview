// SPDX-License-Identifier: GPL-3.0-or-later
//
// 平台探针，对应 macOS 的 EVEOProbe（docs/windows/architecture.md 8.2 节、8.3 节）。
//
// - `ci --fake-client <exefile.exe 的路径> --out <目录>`：在 CI 的 Windows 运行器上启动几个假客户端，
//   逐项核对发现、DWM 缩略图、激活、热键与窗口事件，截图与 report.json 写到目录里；必需项失败时退出码为 1。
// - `report --out <文件> [--redact] [--activate]`：在装了真实客户端的机器上收集待实测的事实（W1、W3、W5 等），
//   写成 JSON。`--redact` 把角色名换成编号；`--activate` 会依次把每个客户端切到前台以测激活。
// - `list`：列出全部顶层窗口，排查发现规则时用。
// - `update-feed --exe <路径> --version <版本> --dir <目录> --port <端口>`：本机测试更新源，用一次性测试密钥签名，
//   在 127.0.0.1 上提供 Release 列表与附件，真机测试自动更新时用（见 update_feed 模块）。
// - `package-check --zip <路径> --version <版本> [--build-label <标签>]`：发布前用应用自己的解包与版本核对检查发布包（见 package_check 模块）。
// - `nvidia status | enable <帧数> --record <文件> | disable --record <文件>`：真机核对 NVIDIA 驱动限帧（见 nvidia 模块）。

//! EVE-O Preview Windows 版的平台探针。

#[cfg(windows)]
mod ci;
#[cfg(windows)]
mod nvidia;
#[cfg(windows)]
mod package_check;
#[cfg(windows)]
mod report;
#[cfg(windows)]
mod update_feed;

#[cfg(windows)]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("ci") => ci::run(&args[1..]),
        Some("report") => report::run(&args[1..]),
        Some("list") => report::list(),
        Some("update-feed") => update_feed::run(&args[1..]),
        Some("package-check") => package_check::run(&args[1..]),
        Some("nvidia") => nvidia::run(&args[1..]),
        _ => {
            eprintln!(
                "用法：eveo-probe ci --fake-client <路径> --out <目录> [--app <路径>] | report --out <文件> [--redact] [--activate] | list | update-feed --exe <路径> --version <版本> --dir <目录> --port <端口> | package-check --zip <路径> --version <版本> [--build-label <标签>] | nvidia status|enable <帧数>|disable --record <文件>"
            );
            2
        }
    };
    std::process::exit(code);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("eveo-probe 只能在 Windows 上运行");
    std::process::exit(2);
}

/// 取 `--name value` 形式的参数值。
#[cfg(windows)]
fn option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|pair| pair[0] == name)
        .map(|pair| pair[1].as_str())
}
