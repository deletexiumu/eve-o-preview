// SPDX-License-Identifier: GPL-3.0-or-later
//
// 新应用的签名核对（v1.1 设计 9.3 节第 6、10 步）。核对的是暂存目录里将要安装的那一份，不是 dmg 里的那一份。
//
// 做法：`SecStaticCodeCreateWithPath` 取静态代码；`SecRequirementCreateWithString` 把正在运行的应用的
// 指定要求编译成要求；再调 `SecStaticCodeCheckValidityWithErrors`，标志是 `kSecCSStrictValidate`、
// `kSecCSCheckAllArchitectures`、`kSecCSCheckNestedCode`。证书不受系统信任不影响结果（U6）。
// 返回 -67050（`errSecCSReqFailed`）时是「不满足指定要求」，其他非 0 值是「签名无效」。
//
// 另有 `signatureInfo(at:)`：读任意一个包的签名信息，供探针在不运行应用的情况下拿一个包当作「正在运行的应用」。

import Foundation
import EVEOPreviewCore
import Security

/// 代码签名的核对。
public enum CodeSignatureVerifier {
    /// `errSecCSReqFailed`：代码不满足给定的要求。
    public static let requirementFailedStatus: OSStatus = -67050
    /// 核对用的标志。
    static let validityFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        | kSecCSCheckNestedCode)

    /// 核对 bundleURL 的签名并要求它满足 requirement 文本。返回 Security 框架的返回值，0 表示通过。
    ///
    /// requirement 编译失败时返回编译的错误码（不是 0）。
    public static func check(bundleAt bundleURL: URL, requirement: String) -> OSStatus {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return createStatus }
        var compiled: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard requirementStatus == errSecSuccess, let compiled else { return requirementStatus }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, validityFlags, compiled, &error)
        error?.release()
        return status
    }

    /// 把核对的返回值换成 `UpdateError`；0 返回 nil。
    public static func error(for status: OSStatus) -> UpdateError? {
        switch status {
        case errSecSuccess: return nil
        case requirementFailedStatus: return .requirementNotSatisfied
        default: return .signatureInvalid(status: status)
        }
    }

    /// 读一个包的签名信息，口径与 `AppEnvironmentProvider` 读本进程时相同。读不到时类别是 `.unknown`。
    public static func signatureInfo(at bundleURL: URL) -> CodeSignatureInfo {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return CodeSignatureInfo(kind: .unknown) }
        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &rawInfo) == errSecSuccess,
              let info = rawInfo as? [String: Any] else { return CodeSignatureInfo(kind: .unknown) }
        let isSigned = info[kSecCodeInfoIdentifier as String] != nil
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        var signer: String?
        if let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            var name: CFString?
            if SecCertificateCopyCommonName(leaf, &name) == errSecSuccess { signer = name as String? }
        }
        let kind = AppEnvironmentRules.signatureKind(isSigned: isSigned, isAdHoc: isAdHoc, signerName: signer)
        return CodeSignatureInfo(kind: kind, signerName: signer,
                                 designatedRequirement: isSigned ? designatedRequirement(staticCode) : nil)
    }

    /// 指定要求的文本；读不到时返回 nil。
    private static func designatedRequirement(_ staticCode: SecStaticCode) -> String? {
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}
