// SPDX-License-Identifier: GPL-3.0-or-later
//
// 报告窗口的内容（v1.1 设计 7.4 节）：
// - 顶部：手动情境显示 `intro`，崩溃情境显示 `crashIntro`；下面一行是 `redactionNote`。
// - 左栏：文件列表，每行有勾选框、名称、大小。`summary.md` 与 `manifest.json` 的勾选框不可用。
// - 右栏：选中文件脱敏后的文字，等宽字体，只读，可选择复制。超过 200,000 个字符时只显示开头并注明；下面一行是替换次数。
// - 底部按钮：手动情境是「取消」「只生成报告」「生成报告并打开 GitHub」；崩溃情境把「取消」换成「不报告」和「以后再说」。
// - 收集期间显示进度指示，生成按钮不可用。完成页是 `doneHelp` 与「在访达中显示」「再次打开 GitHub」「关闭」。
//
// 预览用 `NSTextView`：SwiftUI 的 `Text` 显示几十万个字符时卡顿。
// 文件大小用 `ByteCountFormatStyle`，跟随界面语言对应的 `Locale`。

import AppKit
import SwiftUI
import EVEOPreviewCore

/// 报告窗口的根视图。
struct ProblemReportView: View {
    /// 窗口的状态。
    @Bindable var model: ProblemReportModel
    /// 流程控制器，按钮的动作交给它。
    let controller: ProblemReportController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    // MARK: - 顶部

    /// 说明文字与脱敏说明。
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isCrash ? L10n.diagnostics.crashIntro : L10n.diagnostics.intro)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.diagnostics.redactionNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 中间

    /// 按阶段显示进度、文件列表与预览，或完成页。
    @ViewBuilder private var content: some View {
        switch model.phase {
        case .collecting:
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.diagnostics.collecting).foregroundStyle(.secondary)
            }
        case .review, .creating:
            HStack(spacing: 0) {
                fileList
                    .frame(width: 250)
                Divider()
                preview
            }
        case .done:
            donePage
        }
    }

    /// 左栏的文件列表。
    private var fileList: some View {
        List(selection: $model.selectedID) {
            Section(L10n.diagnostics.itemsHeader) {
                ForEach(model.displayItems) { item in
                    fileRow(item).tag(item.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// 文件列表的一行：勾选框、名称、大小。
    private func fileRow(_ item: ReportItem) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: inclusionBinding(item))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(item.isRequired || model.phase != .review)
            VStack(alignment: .leading, spacing: 1) {
                Text(ProblemReportView.title(for: item)).lineLimit(1)
                if item.kind == .log {
                    Text((item.relativePath as NSString).lastPathComponent)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(ProblemReportView.size(item.contents.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 勾选框的绑定；必留的文件总是勾选。
    private func inclusionBinding(_ item: ReportItem) -> Binding<Bool> {
        Binding(get: { item.isRequired || model.included.contains(item.id) },
                set: { on in
                    guard !item.isRequired else { return }
                    if on { model.included.insert(item.id) } else { model.included.remove(item.id) }
                })
    }

    /// 右栏：选中文件的脱敏全文、截断说明与替换次数。
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let item = model.selectedItem {
                ReadOnlyTextView(text: item.previewText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if item.isPreviewTruncated {
                    Text(L10n.diagnostics.previewTruncated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.diagnostics.replacements(item.counts.total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
            }
        }
        .padding(8)
    }

    /// 完成页。
    private var donePage: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(L10n.diagnostics.doneTitle).font(.title2.bold())
            Text(L10n.diagnostics.doneHelp)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            if let zip = model.archiveURL {
                Text(zip.lastPathComponent)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
    }

    // MARK: - 底部

    /// 底部的错误说明（单独一行）与按钮。崩溃情境有 4 个按钮，俄文约 640 点宽，按钮不压缩。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.phase == .creating {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) { buttons }
                    .fixedSize()
            }
        }
    }

    /// 按阶段与情境排列的按钮。
    @ViewBuilder private var buttons: some View {
        if model.phase == .done {
            Button(L10n.diagnostics.revealButton) { controller.revealArchive() }
            Button(L10n.diagnostics.openIssueButton) { controller.reopenIssue() }
                .disabled(model.issueURL == nil)
            Button(L10n.diagnostics.closeButton) { controller.closeWindow() }
                .keyboardShortcut(.defaultAction)
        } else {
            if model.isCrash {
                Button(L10n.diagnostics.dontReportButton) { controller.dontReport() }
                Button(L10n.diagnostics.notNowButton) { controller.closeWindow() }
            } else {
                Button(L10n.diagnostics.cancelButton) { controller.closeWindow() }
                    .keyboardShortcut(.cancelAction)
            }
            Button(L10n.diagnostics.createOnlyButton) { controller.createReport(openIssue: false) }
                .disabled(model.phase != .review)
            Button(L10n.diagnostics.createAndOpenButton) { controller.createReport(openIssue: true) }
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase != .review)
        }
    }

    // MARK: - 文字

    /// 文件在列表里的名称。
    static func title(for item: ReportItem) -> String {
        switch item.kind {
        case .summary: return L10n.diagnostics.itemSummary
        case .config: return L10n.diagnostics.itemConfig
        case .log: return L10n.diagnostics.itemLog
        case .crash(let number): return L10n.diagnostics.itemCrash(number)
        case .manifest: return L10n.diagnostics.itemManifest
        }
    }

    /// 文件大小，按界面语言的 `Locale` 显示。
    static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file).locale(Locale(identifier: L10n.language.rawValue)))
    }
}

/// 只读、可选择复制的等宽文字视图。
struct ReadOnlyTextView: NSViewRepresentable {
    /// 显示的文字。
    let text: String

    /// 建带滚动条的文本视图：不可编辑，可选择，不自动换行替换引号与破折号。
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 4, height: 4)
            textView.string = text
        }
        return scrollView
    }

    /// 文字变了时替换内容并滚回开头。
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}
