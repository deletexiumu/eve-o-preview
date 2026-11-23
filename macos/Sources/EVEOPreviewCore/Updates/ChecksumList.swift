// SPDX-License-Identifier: GPL-3.0-or-later
//
// `SHA256SUMS.txt` 的解析（v1.1 设计 9.2 节）。文件是 `shasum -a 256` 的输出：
// 每行 64 位十六进制、分隔、文件名。分隔是两个空格（文本模式）或一个空格加 `*`（二进制模式）。
//
// 规则：空行与 `#` 开头的行跳过，行尾的回车去掉；十六进制不区分大小写，结果转成小写；
// 文件名是分隔之后到行尾的全部内容，可以含空格，含 `/` 或 `\` 时这一行无效。
// 任何一行无效，或同一个文件名出现两个不同的值，整个文件无效；相同的重复行可以接受。

import Foundation

/// 校验和文件的解析。
public enum ChecksumList {
    /// 一个 SHA-256 的十六进制位数。
    static let digestLength = 64

    /// 解析整个文件，返回「文件名 → 小写十六进制」。文件无效时抛 `checksumListInvalid`。
    public static func parse(_ text: String) throws(UpdateError) -> [String: String] {
        var result: [String: String] = [:]
        // Swift 把 "\r\n" 当作一个字符，只按 "\n" 切分会漏掉 CRLF 的行，所以两种都算行尾。
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        for rawLine in lines {
            var line = Substring(rawLine)
            if line.hasSuffix("\r") { line = line.dropLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let (name, digest) = entry(line) else { throw .checksumListInvalid }
            if let existing = result[name], existing != digest { throw .checksumListInvalid }
            result[name] = digest
        }
        return result
    }

    /// 按文件名完全相等查找期望的 SHA-256。文件无效时抛 `checksumListInvalid`，找不到时抛 `checksumEntryMissing`。
    public static func expectedHash(for fileName: String, in text: String) throws(UpdateError) -> String {
        let entries = try parse(text)
        guard let digest = entries[fileName] else { throw .checksumEntryMissing(fileName) }
        return digest
    }

    /// 解析一行，返回（文件名，小写十六进制）；格式不对时返回 nil。
    private static func entry(_ line: Substring) -> (String, String)? {
        let characters = Array(line)
        // 64 位十六进制 + 2 个分隔字符 + 至少 1 个字符的文件名。
        guard characters.count >= digestLength + 3 else { return nil }
        let digest = characters[0..<digestLength]
        guard digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let separator = String(characters[digestLength..<(digestLength + 2)])
        guard separator == "  " || separator == " *" else { return nil }
        let name = String(characters[(digestLength + 2)...])
        guard !name.contains("/"), !name.contains("\\") else { return nil }
        return (name, String(digest).lowercased())
    }
}
