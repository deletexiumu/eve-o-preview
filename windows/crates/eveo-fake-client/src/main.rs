// SPDX-License-Identifier: GPL-3.0-or-later
//
// 假的 EVE 客户端窗口，只用于集成探针（架构文档 8.2 节）。一个普通的带边框顶层窗口：
// 类名默认 trinityWindow，标题、客户区颜色、位置与大小由参数给出，客户区涂成纯色，便于在截图里核对。
// CI 把可执行文件复制成 exefile.exe 再启动，进程名就与真客户端相同。
//
// 参数：--title <标题>（默认 "EVE"）、--color <RRGGBB>（默认 808080）、--class <类名>、
//       --x、--y、--width、--height（客户区大小，默认 1280×720）。

//! 集成测试用的假 EVE 客户端。

#[cfg(windows)]
mod app;

#[cfg(windows)]
fn main() {
    if let Err(error) = app::run(std::env::args().skip(1).collect()) {
        eprintln!("eveo-fake-client: {error}");
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("eveo-fake-client 只能在 Windows 上运行");
    std::process::exit(2);
}
