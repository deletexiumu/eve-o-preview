// SPDX-License-Identifier: GPL-3.0-or-later
//
// 运行环境（v1.1 设计 4.2 节）：正在运行的是哪种构建、装在哪里。
// Platform 的 `AppEnvironmentProvider` 在启动时读一次，之后不变；更新功能与问题报告都用它。
// 本文件只有值类型与两条纯规则，规则表见 4.2 节，测试在 AppEnvironmentRulesTests。

import Foundation

/// 代码签名的类别。只用来给构建分类和决定界面上的说明；新版本是否可信看指定要求（9.3 节）。
public enum SignatureKind: String, Sendable, Codable, CaseIterable {
    /// 用发布证书 `EVE-O Preview Release` 签名。
    case release
    /// 用别的证书签名，如本机的 `EVEO Preview Dev`。
    case development
    /// ad-hoc 签名，指定要求只是 cdhash（U4）。
    case adHoc
    /// 没有签名。
    case unsigned
    /// 读签名信息失败。
    case unknown
}

/// 启动时读到的签名信息。
public struct CodeSignatureInfo: Sendable, Equatable {
    /// 签名的类别。
    public var kind: SignatureKind
    /// 叶证书的通用名称；ad-hoc 与未签名时是 nil。
    public var signerName: String?
    /// 启动时读到的指定要求的文本；读不到时是 nil。安装更新时用它核对新版本（9.3 节第 6 步）。
    public var designatedRequirement: String?

    /// 用各字段建签名信息。
    public init(kind: SignatureKind, signerName: String? = nil, designatedRequirement: String? = nil) {
        self.kind = kind
        self.signerName = signerName
        self.designatedRequirement = designatedRequirement
    }
}

/// 安装位置的类别。
public enum InstallLocationKind: String, Sendable, Codable, CaseIterable {
    /// `/Applications/` 下。
    case applications
    /// `~/Applications/` 下。
    case userApplications
    /// 其他可写的位置，如下载文件夹。
    case other
    /// 系统把带隔离属性的应用放到随机的只读路径下运行（转移运行）。
    case translocated
    /// 只读卷，如直接从 dmg 里打开。
    case readOnlyVolume
    /// 不是从 `.app` 运行（`swift run`）。
    case notBundled
}

/// 正在运行的应用的版本、签名与安装位置。
public struct AppEnvironment: Sendable, Equatable {
    /// bundle id。
    public var bundleIdentifier: String
    /// `CFBundleShortVersionString`；没有时是 `"0.0.0"`。
    public var version: String
    /// `Info.plist` 的 `EVEOBuildLabel`，如 `1.1.0-pr.12.abc1234`；没有时等于 `version`。
    public var buildLabel: String
    /// `Info.plist` 的 `EVEOBuildCommit`，提交的前 7 位；没有时是 nil。
    public var buildCommit: String?
    /// `.app` 包的路径；nil 表示不是从 `.app` 运行。
    public var bundlePath: String?
    /// 可执行文件名，发布包里是 `EVEOPreview`。
    public var executableName: String
    /// 签名信息。
    public var signature: CodeSignatureInfo
    /// 安装位置的类别。
    public var location: InstallLocationKind
    /// 包所在目录与包本身对当前用户是否都可写。
    public var isLocationWritable: Bool

    /// 用各字段建运行环境。测试与假服务用；真实值由 `AppEnvironmentProvider.current()` 读取。
    public init(bundleIdentifier: String, version: String, buildLabel: String, buildCommit: String?,
                bundlePath: String?, executableName: String, signature: CodeSignatureInfo,
                location: InstallLocationKind, isLocationWritable: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.buildLabel = buildLabel
        self.buildCommit = buildCommit
        self.bundlePath = bundlePath
        self.executableName = executableName
        self.signature = signature
        self.location = location
        self.isLocationWritable = isLocationWritable
    }
}

/// 运行环境的分类规则（4.2 节的两张表）。
public enum AppEnvironmentRules {
    /// 发布证书的通用名称。
    public static let releaseSignerName = "EVE-O Preview Release"

    /// 签名类别，按顺序取第一个成立的：没签名 → `.unsigned`；ad-hoc → `.adHoc`；
    /// 证书名等于 `releaseSignerName` → `.release`；其他 → `.development`。
    public static func signatureKind(isSigned: Bool, isAdHoc: Bool, signerName: String?) -> SignatureKind {
        if !isSigned { return .unsigned }
        if isAdHoc { return .adHoc }
        if signerName == releaseSignerName { return .release }
        return .development
    }

    /// 安装位置类别，按顺序取第一个成立的：没有包 → `.notBundled`；路径含 `/AppTranslocation/` → `.translocated`；
    /// 只读卷 → `.readOnlyVolume`；`/Applications/` 下 → `.applications`；
    /// `<homeDirectory>/Applications/` 下 → `.userApplications`；其他 → `.other`。
    ///
    /// - Parameter homeDirectory: 当前用户的主目录，末尾有没有 `/` 都可以。
    public static func locationKind(bundlePath: String?, homeDirectory: String, isReadOnlyVolume: Bool)
        -> InstallLocationKind {
        guard let bundlePath else { return .notBundled }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if isReadOnlyVolume { return .readOnlyVolume }
        if bundlePath.hasPrefix("/Applications/") { return .applications }
        // 主目录为空时不做这一项判断，否则 "/Applications/" 的前缀会被当成用户的应用程序文件夹。
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if !home.isEmpty, bundlePath.hasPrefix(home + "/Applications/") { return .userApplications }
        return .other
    }
}
