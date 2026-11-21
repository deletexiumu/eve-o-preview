// SPDX-License-Identifier: GPL-3.0-or-later
//
// API Key 的钥匙串存储（docs/design-intel-translate.md 7.7 节）：通用密码，服务名
// `io.github.deletexiumu.eveopreview-macos.translation`，账户名是 `apikey.<预设编号>`。
// allowsInteraction 为假时给查询加「不显示界面」的选项，要用户确认时返回 interactionRequired（V33）。
// WP-0 的空实现：不碰钥匙串，读写都返回 errSecUnimplemented（-4）。实现归 WP-C。Key 不写进任何日志。

import Foundation
import EVEOPreviewCore

/// 钥匙串里的 API Key。
public final class KeychainSecretStore: SecretStore {
    /// 钥匙串项的服务名。
    public static let service = "io.github.deletexiumu.eveopreview-macos.translation"
    /// 「未实现」的状态码（errSecUnimplemented）。
    static let unimplemented: Int32 = -4

    /// 建存储。
    public init() {}

    /// 读一项。WP-0 的空实现返回失败。
    public func read(account: String, allowsInteraction: Bool) -> SecretReadResult {
        .failed(status: Self.unimplemented)
    }

    /// 写一项。WP-0 的空实现抛失败。
    public func write(_ secret: String, account: String) throws(SecretStoreError) {
        throw .failed(status: Self.unimplemented)
    }

    /// 删一项。WP-0 的空实现抛失败。
    public func delete(account: String) throws(SecretStoreError) {
        throw .failed(status: Self.unimplemented)
    }
}
