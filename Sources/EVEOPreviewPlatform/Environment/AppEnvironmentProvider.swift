// SPDX-License-Identifier: GPL-3.0-or-later
//
// 读正在运行的应用的版本、签名与安装位置（v1.1 设计 4.2 节）。启动时调一次，结果在本次运行内不变。
//
// - 版本：Info.plist 的 `CFBundleShortVersionString`、`EVEOBuildLabel`、`EVEOBuildCommit`（后两个由构建脚本写入）。
// - 签名：`SecCodeCopySelf` → `SecCodeCopyStaticCode` → `SecCodeCopySigningInformation`。
//   flags 里的 adhoc 位表示 ad-hoc；第一个证书的通用名称是签名者；指定要求用 `SecRequirementCopyString` 转成文本。
//   任何一步失败时类别取 `.unknown`。
// - 位置：只读卷看 `volumeIsReadOnlyKey`；可写看包所在目录与包本身是否都能 `access(_, W_OK)`。

import Foundation
import EVEOPreviewCore
import Security

/// 运行环境的读取。
public enum AppEnvironmentProvider {
    /// 读正在运行的应用的版本、签名与安装位置。启动时调一次，结果在本次运行内不变。
    public static func current() -> AppEnvironment {
        let bundle = Bundle.main
        let info = bundle.infoDictionary ?? [:]
        let version = nonEmpty(info["CFBundleShortVersionString"]) ?? "0.0.0"
        let bundleURL = bundle.bundleURL
        let bundlePath = bundleURL.pathExtension == "app" ? bundleURL.path : nil
        let volume = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeSupportsSwapRenamingKey])
        let isReadOnly = volume?.volumeIsReadOnly ?? false
        let location = AppEnvironmentRules.locationKind(bundlePath: bundlePath, homeDirectory: NSHomeDirectory(),
                                                        isReadOnlyVolume: isReadOnly)
        let executable = nonEmpty(info["CFBundleExecutable"]) ?? bundle.executableURL?.lastPathComponent
            ?? "EVEOPreview"
        return AppEnvironment(bundleIdentifier: bundle.bundleIdentifier ?? PlatformLog.subsystem,
                              version: version,
                              buildLabel: nonEmpty(info["EVEOBuildLabel"]) ?? version,
                              buildCommit: nonEmpty(info["EVEOBuildCommit"]),
                              bundlePath: bundlePath,
                              executableName: executable,
                              signature: signatureInfo(),
                              location: location,
                              isLocationWritable: bundlePath.map(isWritable(bundlePath:)) ?? false,
                              volumeSupportsSwap: volume?.volumeSupportsSwapRenaming ?? true)
    }

    /// Info.plist 里的字符串值；不是字符串或为空时返回 nil。
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 包所在目录与包本身对当前用户是否都可写。
    private static func isWritable(bundlePath: String) -> Bool {
        let parent = (bundlePath as NSString).deletingLastPathComponent
        return access(parent, W_OK) == 0 && access(bundlePath, W_OK) == 0
    }

    // MARK: - 签名

    /// 读本进程的签名信息。读不到签名信息时类别是 `.unknown`；指定要求读不到时只是它为 nil。
    static func signatureInfo() -> CodeSignatureInfo {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return CodeSignatureInfo(kind: .unknown) }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return CodeSignatureInfo(kind: .unknown)
        }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any] else { return CodeSignatureInfo(kind: .unknown) }
        // 没有签名的代码也能读出信息字典，但里面没有标识符。
        let isSigned = info[kSecCodeInfoIdentifier as String] != nil
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let signer = signerName(info)
        let kind = AppEnvironmentRules.signatureKind(isSigned: isSigned, isAdHoc: isAdHoc, signerName: signer)
        return CodeSignatureInfo(kind: kind, signerName: signer,
                                 designatedRequirement: isSigned ? designatedRequirement(staticCode) : nil)
    }

    /// 证书链里第一个证书（叶证书）的通用名称；ad-hoc 与未签名时没有证书，返回 nil。
    private static func signerName(_ info: [String: Any]) -> String? {
        guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        var name: CFString?
        guard SecCertificateCopyCommonName(leaf, &name) == errSecSuccess, let name else { return nil }
        return name as String
    }

    /// 指定要求的文本，如 `identifier "…" and certificate leaf = H"…"`；读不到时返回 nil。
    private static func designatedRequirement(_ staticCode: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}
