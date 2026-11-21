// SPDX-License-Identifier: GPL-3.0-or-later
//
// 设置窗口的「关于」页（架构文档 7.4 节）：版本、上游项目与许可证（GPL-3.0）、
// EVE 知识产权声明，以及「本工具只切换窗口焦点，不向多个客户端广播输入」「战斗提醒只读游戏日志」的说明。
// 预警与翻译加一句：只读聊天日志与游戏日志，翻译会把聊天内容发给用户选择的模型服务。
// v1.1 加一句联网说明：只在检查和下载更新时访问 GitHub，问题报告不会自动发送（v1.1 设计 10.1 节）。

import SwiftUI

/// 「关于」页。
struct AboutPage: View {
    /// 视图模型（只读取演示模式与配置文件位置）。
    let model: SettingsViewModel

    /// 上游项目的地址。
    private static let upstreamURL = URL(string: "https://github.com/EveOPlus/eve-o-preview")!
    /// GPL-3.0 许可证全文的地址。
    private static let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!

    /// 版本号：发布包取 Info.plist，`swift run` 时没有 Info.plist，显示「开发版」。
    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return L10n.settings.devVersion }
        let build = info?["CFBundleVersion"] as? String ?? short
        return build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.settings.version, value: version)
                Text(L10n.settings.aboutSummary).fixedSize(horizontal: false, vertical: true)
            } header: {
                PageHeader(title: L10n.appName, subtitle: L10n.settings.aboutSubtitle)
            }
            // 上游项目与许可证：GPL-3.0 要求标明来源与许可证。
            Section(L10n.settings.upstreamHeader) {
                Text(L10n.settings.upstreamText).fixedSize(horizontal: false, vertical: true)
                Link("EveOPlus/eve-o-preview", destination: AboutPage.upstreamURL)
                Text(L10n.settings.licenseText).fixedSize(horizontal: false, vertical: true)
                Link("GNU GPL v3.0", destination: AboutPage.licenseURL)
            }
            // 说明：只切换焦点、不广播输入（与上游的边界相同，见架构文档 R7），
            // 战斗提醒只读游戏日志（反馈文档 R17），以及 CCP 商标声明。
            Section(L10n.settings.disclaimerHeader) {
                Text(L10n.settings.focusOnlyText).fixedSize(horizontal: false, vertical: true)
                Text(L10n.settings.gameLogText).fixedSize(horizontal: false, vertical: true)
                // 预警与翻译只读日志；翻译把聊天内容发给用户选的模型服务（docs/design-intel-translate.md R32、R38）。
                Text(L10n.settings.aboutChatLogsNote).fixedSize(horizontal: false, vertical: true)
                Text(L10n.settings.networkText).fixedSize(horizontal: false, vertical: true)
                Text(L10n.settings.eveIPText).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
