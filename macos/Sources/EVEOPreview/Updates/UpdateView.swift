// SPDX-License-Identifier: GPL-3.0-or-later
//
// 更新窗口的内容（v1.1 设计 8.6 节）。按 `UpdateController` 的 `phase` 与 `capability` 显示；
// 控制器是 `@Observable`，阶段变化时视图自己刷新。窗口本身（尺寸、弹出方式）在 UpdateWindowController.swift。
//
// 布局自上而下：标题行（新版本、当前版本、「测试地址」字样）、提示条（不能自动安装的原因、失败的说明）、
// 发布说明（可滚动，跳过了几个版本时按版本分段，8.8 节）或状态、按钮区。各阶段的按钮：
//
// | 阶段 | 按钮区 |
// | --- | --- |
// | `available`，能安装 | 「跳过此版本」「稍后」「安装更新」，上方一行说明安装后会重新启动 |
// | `available`，只提示或停用 | 「跳过此版本」「稍后」「打开发布页」，原因显示在发布说明上方 |
// | `downloading`、`verifying` | 进度条与「取消」 |
// | `installing` | 进度条与置灰的「取消」 |
// | `relaunching` | 只有进度；重新启动失败（`relaunchFailed`）时是提示条与「关闭」「退出 EVE-O Preview」 |
// | `readyToInstall` | 「稍后」「重新启动以更新到 <版本>」（8.6 节没有写这一种，取菜单项的做法） |
// | `failed` | 「打开发布页」「关闭」「重试」，上方是错误说明与「当前版本没有变化」 |
// | `checking`、`upToDate` | 「关闭」 |
// | `idle` | 「关闭」「立即检查」（8.6 节没有写这一种） |
//
// 「跳过此版本」「稍后」先调控制器，再由窗口自己关闭：控制器不持有窗口。
// `relaunchFailed`（安装成功、新实例 15 秒内没有启动）时阶段停在 `relaunching`，提示条写 `reopenManually`；
// 包已换成新版本，用户退出后重新打开即是新版本，所以按钮区给出「退出」（用菜单的同名文字）。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 更新窗口的内容。
struct UpdateView: View {
    /// 更新功能的控制器。
    let controller: UpdateController
    /// 关窗口。按钮的动作已经交给控制器之后调用，窗口关闭时不再按「稍后」处理。
    let dismiss: @MainActor () -> Void

    var body: some View {
        // 每次求值时取一次文字表：界面语言变了以后窗口重建视图，自然取到新语言。
        let strings = L10n.updates
        let phase = controller.phase
        let release = Self.release(of: phase)
        VStack(alignment: .leading, spacing: 14) {
            header(strings, release: release)
            notice(strings, phase: phase)
            if let release {
                notes(strings, release: release)
            } else {
                status(strings, phase: phase)
            }
            footer(strings, phase: phase)
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 阶段里带的发布信息；`checking`、`upToDate`、`relaunching`、`idle` 与检查失败时没有。菜单项也用它取版本号。
    static func release(of phase: UpdatePhase) -> ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .verifying(let release),
             .readyToInstall(let release), .installing(let release):
            return release
        case .failed(_, let release):
            return release
        case .idle, .checking, .upToDate, .relaunching:
            return nil
        }
    }

    // MARK: - 标题行

    /// 应用图标、标题与当前版本；使用测试地址时标题旁有「测试地址」字样。
    private func header(_ strings: any UpdateStrings, release: ReleaseInfo?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(release.map { strings.headline($0.version) } ?? L10n.appName)
                        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    if controller.feed.isTestFeed {
                        Text(strings.testFeedBadge).font(.caption.bold()).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.orange))
                    }
                }
                Text(strings.currentVersionLine(controller.environment.buildLabel))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 提示条

    /// 发布说明上方的提示：不能自动安装的原因、已下载好待安装、失败的说明。其余阶段没有。
    @ViewBuilder
    private func notice(_ strings: any UpdateStrings, phase: UpdatePhase) -> some View {
        switch phase {
        case .available:
            switch controller.capability {
            case .canInstall: EmptyView()
            case .notifyOnly(let blocker):
                NoticeBanner(text: strings.notifyOnlyIntro + " " + strings.blocker(blocker), systemImage: "info.circle.fill",
                             tint: .blue)
            case .unavailable:
                NoticeBanner(text: strings.statusUnavailable, systemImage: "info.circle.fill", tint: .blue)
            }
        case .readyToInstall(let release):
            NoticeBanner(text: strings.statusReady(release.version), systemImage: "checkmark.circle.fill", tint: .green)
        case .failed(let error, _):
            // `cancelled` 没有说明，只留「当前版本没有变化」。
            let message = [strings.error(error), strings.currentVersionUnchanged].compactMap { $0 }.joined(separator: " ")
            NoticeBanner(text: message)
        case .relaunching:
            if controller.relaunchFailed {
                NoticeBanner(text: strings.reopenManually)
            }
        case .idle, .checking, .upToDate, .downloading, .verifying, .installing:
            EmptyView()
        }
    }

    // MARK: - 发布说明与状态

    /// 「新内容」小标题与可滚动的发布说明。按界面语言取段落；取出的文字为空时只留小标题下的空白区域。
    ///
    /// 跳过了几个版本时（8.8 节），最新版之后依次列出中间各版本的说明，新版在前，每段前有版本小标题，段间有分隔线；
    /// 只有最新版一段时与以前完全一样，没有小标题。中间版本的说明在后台取，取到后视图自己刷新。
    private func notes(_ strings: any UpdateStrings, release: ReleaseInfo) -> some View {
        let sections = [ReleaseNotesEntry(version: release.version, notes: release.notes)]
            + controller.earlierNotes(for: release)
        let showsTitles = sections.count > 1
        let hasMore = controller.hasMoreEarlierNotes(for: release)
        return VStack(alignment: .leading, spacing: 6) {
            Text(strings.releaseNotesHeader).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 以版本号作标识：中间版本后到时，最新版那一段不重建。
                    ForEach(Array(sections.enumerated()), id: \.element.version) { index, entry in
                        if index > 0 { Divider() }
                        if showsTitles {
                            Text(strings.versionNotesTitle(entry.version)).font(.title2.bold())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // 只显示本平台的内容：去掉 Windows 的小节（docs/update-manifest.md 第 4 节第 6 条）。
                        ReleaseNotesView(markdown: ReleaseNotes.platformOnly(
                            ReleaseNotes.section(for: L10n.language, in: entry.notes), own: "macOS"))
                    }
                    if hasMore {
                        Divider()
                        Text(strings.earlierVersionsOnReleasePage).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            // 窗口显示某个版本时补取中间版本（如重启后从缓存恢复的提示）；缓存合用时不发请求。
            .task(id: release.version) { controller.ensureIntermediateNotes(for: release) }
        }
    }

    /// 没有发布信息时窗口中部的状态：检查中、已是最新、重新启动中。空闲与检查失败时只留空白（失败的说明在提示条里）。
    private func status(_ strings: any UpdateStrings, phase: UpdatePhase) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            switch phase {
            case .checking:
                ProgressView().controlSize(.small)
                Text(strings.statusChecking)
            case .upToDate:
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text(strings.statusUpToDate).multilineTextAlignment(.center)
            case .relaunching:
                // 重新启动失败时说明在提示条里，这里不再转圈。
                if !controller.relaunchFailed {
                    ProgressView().controlSize(.small)
                    Text(strings.progressRelaunching)
                }
            case .idle, .available, .downloading, .verifying, .readyToInstall, .installing, .failed:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 按钮区

    /// 各阶段的按钮区，见文件头的表。
    @ViewBuilder
    private func footer(_ strings: any UpdateStrings, phase: UpdatePhase) -> some View {
        switch phase {
        case .available:
            offerButtons(strings)
        case .downloading(_, let progress):
            progressRow(strings.progressDownloading(
                received: UpdateTextFormat.bytes(progress.receivedBytes),
                total: progress.totalBytes.map(UpdateTextFormat.bytes)),
                fraction: Self.fraction(progress), canCancel: true, strings: strings)
        case .verifying:
            progressRow(strings.progressVerifying, fraction: nil, canCancel: true, strings: strings)
        case .installing:
            progressRow(strings.progressInstalling, fraction: nil, canCancel: false, strings: strings)
        case .relaunching:
            if controller.relaunchFailed {
                buttonRow {
                    Button(strings.closeButton) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L10n.menu.quit) { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                }
            }
        case .readyToInstall(let release):
            // 「稍后」只关窗口：已下载好的更新照常在退出时安装，圆点与菜单项保留（9.5 节）。
            buttonRow {
                Button(strings.laterButton) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(strings.menuRestartToUpdate(release.version)) { controller.restartToInstall() }
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(_, let release):
            HStack(spacing: 8) {
                Button(strings.openReleasePageButton) { controller.openReleasePage() }
                Spacer(minLength: 12)
                Button(strings.closeButton) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(strings.retryButton) { retry(release: release) }.keyboardShortcut(.defaultAction)
            }
        case .checking, .upToDate:
            buttonRow {
                Button(strings.closeButton) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        case .idle:
            buttonRow {
                Button(strings.closeButton) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(strings.checkNowButton) { controller.checkNow(userInitiated: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.capability == .unavailable)
            }
        }
    }

    /// 有新版本时的按钮：能安装时是「安装更新」，否则是「打开发布页」。
    private func offerButtons(_ strings: any UpdateStrings) -> some View {
        let canInstall = controller.capability == .canInstall
        return VStack(alignment: .leading, spacing: 10) {
            if canInstall {
                Text(strings.installHelp).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(strings.skipButton) { controller.skipThisVersion(); dismiss() }
                Spacer(minLength: 12)
                Button(strings.laterButton) { controller.remindLater(); dismiss() }.keyboardShortcut(.cancelAction)
                if canInstall {
                    Button(strings.installButton) { controller.install() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(strings.openReleasePageButton) { controller.openReleasePage() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// 进度条、进度文字与「取消」。fraction 为 nil 时是不定进度。
    private func progressRow(_ text: String, fraction: Double?, canCancel: Bool,
                             strings: any UpdateStrings) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(text).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(strings.cancelButton) { controller.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(!canCancel)
        }
    }

    /// 靠右排列的一组按钮。
    private func buttonRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content()
        }
    }

    /// 「重试」：带着发布信息失败的（下载、核对、安装）在能安装时重新安装，其余（检查失败）重新检查。
    private func retry(release: ReleaseInfo?) {
        if release != nil, controller.capability == .canInstall {
            controller.install()
        } else {
            controller.checkNow(userInitiated: true)
        }
    }

    /// 下载进度的比例；总大小未知或为 0 时返回 nil（显示不定进度）。
    private static func fraction(_ progress: UpdateProgress) -> Double? {
        guard let total = progress.totalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(progress.receivedBytes) / Double(total)))
    }
}
