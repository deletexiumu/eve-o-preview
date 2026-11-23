// SPDX-License-Identifier: GPL-3.0-or-later
//
// 日志消息（v1.1 设计 5.1 节）。`os.Logger` 的 `OSLogMessage` 由编译器特殊处理，应用拿不到拼好的文字，
// 所以这里用自己的消息类型代替它：调用处的插值写法与 `os.Logger` 相同（`privacy:`、`format:`），
// 字面量与插值分段保存，渲染时才决定私有值是否显示。
//
// 默认隐私与 `os.Logger` 一致：整数、浮点数、布尔值默认公开；字符串与其他类型默认私有。

import Foundation

/// 插值的隐私标注。
public enum LogPrivacy: Sendable {
    /// 照原样写出。
    case `public`
    /// 不带 `includingPrivate` 渲染时写成 `<private>`。
    case `private`
}

/// 浮点数的格式。
public enum LogNumberFormat: Sendable {
    /// 固定 n 位小数，如 `fixed(precision: 2)` 把 1.5 写成 `1.50`。
    case fixed(precision: Int)
}

/// 一条日志的文字：字面量与插值分段保存，渲染时才决定私有值是否显示。
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    /// 消息的一段。
    public enum Segment: Sendable, Equatable {
        /// 源码里的字面量，总是公开。
        case literal(String)
        /// 插值已转成的文字与它的隐私标注。
        case value(String, LogPrivacy)
    }

    /// 按出现顺序排列的各段。空的字面量不保存，相邻的字面量合并成一段。
    public var segments: [Segment]

    /// 不含插值的字符串字面量。
    public init(stringLiteral value: String) {
        var interpolation = StringInterpolation(literalCapacity: value.count, interpolationCount: 0)
        interpolation.appendLiteral(value)
        segments = interpolation.segments
    }

    /// 编译器为带插值的字符串字面量调用。
    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    /// 插值的收集器。方法签名与 `os.Logger` 的插值一致，调用处的写法不用改。
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        /// 已收集的各段。
        var segments: [Segment]

        /// 编译器按字面量长度与插值个数预留空间。
        public init(literalCapacity: Int, interpolationCount: Int) {
            segments = []
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        /// 追加一段字面量；与上一段字面量相邻时合并。
        public mutating func appendLiteral(_ literal: String) {
            guard !literal.isEmpty else { return }
            if case .literal(let previous)? = segments.last {
                segments[segments.count - 1] = .literal(previous + literal)
            } else {
                segments.append(.literal(literal))
            }
        }

        /// 字符串插值，默认私有（角色名、窗口标题都是字符串）。
        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy = .private) {
            segments.append(.value(value, privacy))
        }

        /// 整数插值，默认公开。
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy = .public) {
            segments.append(.value(String(value), privacy))
        }

        /// 不带 `format` 的浮点数插值，默认公开，按 Swift 的默认写法输出。
        ///
        /// 设计 5.1 节只有下面那个带 `format` 参数的重载。只有它时，`\(x)` 会选中最后那个泛型重载（默认私有）：
        /// 编译器优先选省略的默认参数少的重载，它省略 2 个，泛型重载只省略 1 个。所以另加这个重载，
        /// 让不带 `format` 的浮点数也按 os.Logger 的规则默认公开。
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, privacy: LogPrivacy = .public) {
            appendInterpolation(value, format: nil, privacy: privacy)
        }

        /// 浮点数插值，默认公开。`format` 为 nil 时按 Swift 的默认写法输出。
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, format: LogNumberFormat? = nil,
                                                                         privacy: LogPrivacy = .public) {
            let text: String
            switch format {
            case .fixed(let precision)?:
                // 负的位数按 0 处理，避免格式串出错。
                text = String(format: "%.*f", max(0, precision), Double(value))
            case nil:
                text = String(describing: value)
            }
            segments.append(.value(text, privacy))
        }

        /// 布尔值插值，默认公开，写成 `true` 或 `false`。
        public mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            segments.append(.value(value ? "true" : "false", privacy))
        }

        /// 其他类型的插值，用 `String(describing:)` 转成文字，默认私有。
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .private) {
            segments.append(.value(String(describing: value), privacy))
        }
    }

    /// 拼出整条文字。
    ///
    /// - Parameter includingPrivate: 为假时私有值写成 `<private>`；为真时照原样写出（只用于开发时的系统日志）。
    public func rendered(includingPrivate: Bool) -> String {
        var result = ""
        for segment in segments {
            switch segment {
            case .literal(let text):
                result += text
            case .value(let text, .public):
                result += text
            case .value(let text, .private):
                result += includingPrivate ? text : LogMessage.privatePlaceholder
            }
        }
        return result
    }

    /// 私有值在文件日志里的写法。
    public static let privatePlaceholder = "<private>"
}
