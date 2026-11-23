// SPDX-License-Identifier: GPL-3.0-or-later
//
// 宽松的枚举解码（反馈文档 3.2 节）。decodeIfPresent(枚举.self) 遇到不认识的值会抛错，
// 整个配置文件会被当成损坏文件隔离；以后的版本新增取值后，旧版本应退回默认值，而不是丢掉全部配置。
// 第一轮反馈起新增的枚举键都用这里的函数解码。现有的 ZoomAnchor 仍按原方式解码。

import Foundation

/// 宽松解码的工具函数。
public enum LenientDecoding {
    /// 解码一个以字符串为原始值的枚举。键缺失、类型不对或值不认识时返回 fallback，不抛错。
    ///
    /// 退回默认值时不产生 `ConfigWarning`，下次保存时文件里的值被默认值覆盖。
    public static func value<T: RawRepresentable & Sendable, K: CodingKey>(
        _ type: T.Type, in container: KeyedDecodingContainer<K>, forKey key: K, default fallback: T
    ) -> T where T.RawValue == String {
        // 用 try? decode 而不是 decodeIfPresent：后者在类型不对（如 "language": 5）时同样会抛错。
        guard let raw = try? container.decode(String.self, forKey: key) else { return fallback }
        return T(rawValue: raw) ?? fallback
    }
}
