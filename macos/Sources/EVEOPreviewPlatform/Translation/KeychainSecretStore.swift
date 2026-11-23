// SPDX-License-Identifier: GPL-3.0-or-later
//
// API Key 的钥匙串存储（docs/macos/design-intel-translate.md 7.7 节）：通用密码，服务名
// `io.github.deletexiumu.eveopreview-macos.translation`，账户名是 `apikey.<预设编号>`，存在登录钥匙串里。
// 读取不弹窗（allowsInteraction 为假，V33）用了两层办法，任一层生效都不会弹出系统窗口：
// 1. 查询带 kSecUseAuthenticationContext，LAContext 的 interactionNotAllowed 为真（kSecUseAuthenticationUIFail 的
//    官方替代）。
// 2. 查询期间用 SecKeychainSetUserInteractionAllowed(false) 关掉本进程的钥匙串交互。登录钥匙串是文件钥匙串，
//    「某应用想访问钥匙串项」的确认窗口由这一层管；查询结束后恢复原值。调用只在主线程（9.4 节）。
// 系统要用户确认时返回 interactionRequired（errSecInteractionNotAllowed）。写入与删除只在用户操作设置窗口时发生，
// 允许系统弹窗。Key 不写进任何日志；本文件不记日志。

import Foundation
import LocalAuthentication
import Security
import EVEOPreviewCore

/// 钥匙串里的 API Key。
public final class KeychainSecretStore: SecretStore {
    /// 钥匙串项的服务名。
    public static let service = "io.github.deletexiumu.eveopreview-macos.translation"

    /// 本实例使用的服务名。测试可传一个一次性的服务名，用完删掉。
    private let service: String
    /// 关掉钥匙串交互的办法。
    private let gate: any KeychainInteractionGate = LegacyKeychainInteractionGate()

    /// 建存储；service 默认是正式的服务名。
    public init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    /// 读一项。allowsInteraction 为假时不弹系统窗口，要确认时返回 interactionRequired。
    public func read(account: String, allowsInteraction: Bool) -> SecretReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status: OSStatus
        var result: CFTypeRef?
        if allowsInteraction {
            status = SecItemCopyMatching(query as CFDictionary, &result)
        } else {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            let frozen = query
            (status, result) = gate.withoutInteraction {
                var found: CFTypeRef?
                let code = SecItemCopyMatching(frozen as CFDictionary, &found)
                return (code, found)
            }
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                return .failed(status: errSecDecode)
            }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .interactionRequired
        case errSecAuthFailed where !allowsInteraction:
            // 不显示界面时，有的系统版本对需要确认的文件钥匙串项报 errSecAuthFailed。
            return .interactionRequired
        default:
            return .failed(status: status)
        }
    }

    /// 写一项，已有时更新。
    public func write(_ secret: String, account: String) throws(SecretStoreError) {
        let data = Data(secret.utf8)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "EVE-O Preview translation API key (\(account))"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw .failed(status: added) }
        let update = [kSecValueData as String: data] as CFDictionary
        let updated = SecItemUpdate(baseQuery(account: account) as CFDictionary, update)
        guard updated == errSecSuccess else { throw .failed(status: updated) }
    }

    /// 删一项，不存在时不算失败。
    public func delete(account: String) throws(SecretStoreError) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .failed(status: status) }
    }

    /// 通用密码的查询条件：服务名与账户名。
    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// 在关掉钥匙串交互的情况下执行一段代码。
private protocol KeychainInteractionGate: Sendable {
    func withoutInteraction<T>(_ body: () -> T) -> T
}

/// 用 SecKeychainSetUserInteractionAllowed 关掉本进程的钥匙串交互。
///
/// 这组接口从 macOS 10.10 起标为过时，但文件钥匙串（登录钥匙串）的访问确认仍由它管，没有不过时的替代。
/// 方法标成过时，调用处经协议转发，构建时不产生过时警告。
private struct LegacyKeychainInteractionGate: KeychainInteractionGate {
    @available(macOS, deprecated: 10.10)
    func withoutInteraction<T>(_ body: () -> T) -> T {
        var previous: DarwinBoolean = true
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        _ = SecKeychainSetUserInteractionAllowed(false)
        // 读不到原值时按「允许」恢复，这是系统的默认值。
        defer { _ = SecKeychainSetUserInteractionAllowed(readStatus == errSecSuccess ? previous.boolValue : true) }
        return body()
    }
}
