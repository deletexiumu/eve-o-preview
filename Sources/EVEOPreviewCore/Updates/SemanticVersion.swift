// SPDX-License-Identifier: GPL-3.0-or-later
//
// 语义化版本号（v1.1 设计 8.3 节）：解析 tag 与构建标签，按语义化版本 2.0.0 第 11 条比较。
//
// 与规范的差别只有一处：纯数字的预发布段带前导零（如提交号 `0012345`）时不报错，按含字母的段处理，
// 所以 CI 的标签 `1.1.0-pr.12.0012345` 能解析。构建信息（`+` 之后）不参与比较，也不参与相等与哈希。

import Foundation

/// 语义化版本号，如 `1.2.0-beta.1+build.5`。
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// 主版本号。
    public var major: Int
    /// 次版本号。
    public var minor: Int
    /// 修订号。
    public var patch: Int
    /// 预发布标识按 `.` 分段，如 "1.2.0-beta.1" 的 ["beta", "1"]。
    public var prerelease: [String]
    /// "+" 后面的部分按 `.` 分段，不参与比较。
    public var build: [String]

    /// 解析版本号；接受开头的 "v" 或 "V"。格式不对时返回 nil。
    ///
    /// 三段数字都应是非负整数；只有两段或有四段时失败。预发布与构建信息按 `.` 分段，
    /// 每段由 ASCII 字母、数字和 `-` 组成，不能为空。
    public init?(_ text: String) {
        var rest = Substring(text)
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        // 先切掉构建信息，再切预发布标识：预发布标识里可以有 `-`，构建信息里也可以有。
        var buildPart: Substring?
        if let plus = rest.firstIndex(of: "+") {
            buildPart = rest[rest.index(after: plus)...]
            rest = rest[..<plus]
        }
        var prereleasePart: Substring?
        if let dash = rest.firstIndex(of: "-") {
            prereleasePart = rest[rest.index(after: dash)...]
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, let major = SemanticVersion.number(numbers[0]),
              let minor = SemanticVersion.number(numbers[1]), let patch = SemanticVersion.number(numbers[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        if let prereleasePart {
            guard let segments = SemanticVersion.identifiers(prereleasePart) else { return nil }
            prerelease = segments
        } else {
            prerelease = []
        }
        if let buildPart {
            guard let segments = SemanticVersion.identifiers(buildPart) else { return nil }
            build = segments
        } else {
            build = []
        }
    }

    /// 是否带预发布标识。
    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// 规范写法，不带 "v"：`主.次.修订[-预发布][+构建信息]`。
    public var description: String {
        var text = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { text += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { text += "+" + build.joined(separator: ".") }
        return text
    }

    /// 按语义化版本 2.0.0 第 11 条比较；构建信息不参与。
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 数字相同时，没有预发布标识的更大。
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            return identifierLess(left, right)
        }
        // 前面各段都相同时，段数多的更大。
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// 相等只看三段数字与预发布标识。
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    /// 哈希与相等的口径一致，不含构建信息。
    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    // MARK: - 解析与比较的工具

    /// 一段非负整数：只含 ASCII 数字，不为空，不溢出。
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// 按 `.` 分段并逐段核对字符；有空段或非法字符时返回 nil。
    private static func identifiers(_ text: Substring) -> [String]? {
        let segments = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return nil }
        for segment in segments {
            guard !segment.isEmpty, segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return nil }
        }
        return segments.map(String.init)
    }

    /// 一段预发布标识的数值；不是纯数字，或纯数字但带前导零时返回 nil（按含字母的段处理）。
    private static func numericValue(_ identifier: String) -> Int? {
        guard identifier.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if identifier.count > 1, identifier.hasPrefix("0") { return nil }
        return Int(identifier)
    }

    /// 两段预发布标识的比较：都是数字按数值；否则纯数字的更小；都含字母按 ASCII 顺序。
    private static func identifierLess(_ left: String, _ right: String) -> Bool {
        switch (numericValue(left), numericValue(right)) {
        case let (l?, r?): return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8))
        }
    }
}
