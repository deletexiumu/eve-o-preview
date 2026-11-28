// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新状态机的交互入口与查询方法：后台下载状态查询、空闲自动安装临近判断、窗口按钮
// （「安装更新」「重新启动以更新」「跳过此版本」「稍后」「取消」「打开发布页」）。
// 从 machine.rs 分出来是为了让单个文件不超过 1000 行；这里是 machine 的子模块，直接用状态机的私有字段与
// 私有方法（current_release、is_busy、rederive、start_install），行为与放在 machine.rs 里完全相同。
//
// 后台下载与手动操作的协作约定：
// - 后台静默下载进行中（`is_background_downloading()` 为真）：用户尚未点击「安装更新」，
//   点击「安装更新」会把该次下载直接提升为立即安装（不重启下载），点击「跳过此版本」会发取消并回到空闲，
//   点击「稍后」或关闭窗口则让下载继续在后台完成并停在「待安装」。
// - 临近 1 分钟空闲安装阈值（`is_idle_install_imminent()` 为真）：通知应用层绕过 1 秒进程快照缓存，
//   立刻执行一次实时 EVE 进程检查，避免刚启动但尚未建窗的客户端被静默重启打断。

use super::*;

impl UpdateMachine {
    /// 是否正在后台静默下载或核对（用户尚未点击「安装更新」）。
    pub fn is_background_downloading(&self) -> bool {
        matches!(
            self.phase,
            UpdatePhase::Downloading(..) | UpdatePhase::Verifying(_)
        ) && self.job.is_none()
    }

    /// 是否即将达到空闲自动安装的 1 分钟阈值（提前 2 秒起由应用层做实时进程复核，避免进程快照缓存滞后）。
    pub fn is_idle_install_imminent(&self, now: f64) -> bool {
        matches!(self.phase, UpdatePhase::ReadyToInstall(_))
            && self.switches.check
            && self.switches.auto_install
            && !self.is_terminating
            && self
                .idle_since
                .is_some_and(|since| now - since >= IDLE_INSTALL_DELAY - 2.0)
    }

    /// 窗口的「安装更新」：下载（已有可用的下载时跳过）、安装、重新启动。只提示的构建改为打开发布页。
    /// 若当前正处于后台静默下载，直接把该次下载提升为立即安装，不重复下载。
    pub fn install(&mut self, state: &mut UpdateState) -> Vec<Command> {
        match self.capability {
            InstallCapability::Unavailable => Vec::new(),
            InstallCapability::NotifyOnly(_) => vec![self.release_page_command(state)],
            InstallCapability::CanInstall => match self.current_release().cloned() {
                Some(release) if self.is_background_downloading() => {
                    self.background_from_user_check = false;
                    self.job = Some(InstallJob {
                        release,
                        relaunch: true,
                        user_initiated: true,
                    });
                    Vec::new()
                }
                Some(release) if !self.is_busy() => self.start_install(state, release, true, true),
                _ => Vec::new(),
            },
        }
    }

    /// 托盘菜单的「重新启动以更新」，以及空闲时的自动安装。
    pub fn restart_to_install(&mut self, state: &mut UpdateState) -> Vec<Command> {
        if self.capability != InstallCapability::CanInstall || self.is_busy() || self.is_terminating {
            return Vec::new();
        }
        match self.phase.clone() {
            UpdatePhase::ReadyToInstall(release) => self.start_install(state, release, true, false),
            _ => Vec::new(),
        }
    }

    /// 「跳过此版本」：只影响自动检查。已下载的同一版本一并丢掉；后台下载进行中时同时取消下载。
    ///
    /// 不关窗口（窗口自己关）。用户主动触发的安装流程进行中不能跳过：先取消，或等它结束。
    pub fn skip(&mut self, state: &mut UpdateState) -> Vec<Command> {
        let Some(release) = self.current_release().cloned() else {
            return Vec::new();
        };
        let cancel_bg = self.is_background_downloading();
        if self.is_busy() && !cancel_bg {
            return Vec::new();
        }
        state.skipped_version = Some(release.version.clone());
        let mut commands = Vec::new();
        if cancel_bg {
            self.background_from_user_check = false;
            commands.push(Command::CancelPrepare);
        }
        if let Some(prepared) = state
            .prepared
            .take_if(|p| SemanticVersion::parse(&p.version) == SemanticVersion::parse(&release.version))
        {
            commands.push(Command::DeleteFile(prepared.exe_path));
        }
        self.phase = UpdatePhase::Idle;
        commands
    }

    /// 取消进行中的下载或核对。安装开始后不能取消。
    pub fn cancel(&mut self) -> Vec<Command> {
        match self.phase {
            UpdatePhase::Downloading(..) | UpdatePhase::Verifying(_) => vec![Command::CancelPrepare],
            _ => Vec::new(),
        }
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
