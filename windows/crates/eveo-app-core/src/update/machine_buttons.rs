// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新状态机的窗口按钮入口：「跳过此版本」「稍后」「打开发布页」。
// 从 machine.rs 分出来只是为了让单个文件不超过 1000 行；这里是 machine 的子模块，直接用状态机的私有字段与
// 私有方法（current_release、is_busy、rederive），行为与放在 machine.rs 里完全相同。
// 「立即安装」「取消」「重新启动以更新」改动下载与安装的流程，仍留在 machine.rs 的对应小节里。

use super::*;

impl UpdateMachine {
    /// 「跳过此版本」：只影响自动检查。已下载的同一版本一并丢掉。
    ///
    /// 不关窗口（窗口自己关）。下载或安装进行中不能跳过：先取消，或等它结束。
    pub fn skip(&mut self, state: &mut UpdateState) -> Vec<Command> {
        let Some(release) = self.current_release().cloned() else {
            return Vec::new();
        };
        if self.is_busy() {
            return Vec::new();
        }
        state.skipped_version = Some(release.version.clone());
        let mut commands = Vec::new();
        if let Some(prepared) = state
            .prepared
            .take_if(|p| SemanticVersion::parse(&p.version) == SemanticVersion::parse(&release.version))
        {
            commands.push(Command::DeleteFile(prepared.exe_path));
        }
        self.phase = UpdatePhase::Idle;
        commands
    }

    /// 「稍后」或关窗口：失败的阶段按记录重新定出（缓存的新版本仍在时回到「可用」）；别的阶段不变。
    /// 「已是最新」与检查中的结果看过就回到空闲。
    ///
    /// 可以连续调用两次（按钮一次、窗口关闭时一次），第二次不改任何状态。
    pub fn later(&mut self, state: &UpdateState) {
        match self.phase {
            UpdatePhase::Failed(..) | UpdatePhase::UpToDate(_) => self.rederive(state),
            _ => {}
        }
    }

    /// 「打开发布页」：当前版本的发布页，没有或地址不合格时打开发布列表。
    pub fn open_release_page(&self, state: &UpdateState) -> Vec<Command> {
        vec![self.release_page_command(state)]
    }

    /// 打开发布页的命令。
    pub(super) fn release_page_command(&self, state: &UpdateState) -> Command {
        let candidate = self
            .current_release()
            .or(state.cached_release.as_ref())
            .map(|release| release.page_url.clone())
            .filter(|url| self.feed.accepts(url));
        Command::OpenUrl(candidate.unwrap_or_else(|| RELEASES_PAGE_URL.to_owned()))
    }
}
