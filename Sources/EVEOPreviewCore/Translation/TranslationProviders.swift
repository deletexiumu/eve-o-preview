// SPDX-License-Identifier: GPL-3.0-or-later
//
// 服务预设与接口设置的解析（docs/design-intel-translate.md 7.3 节）。
// - presets：7 个预设。预设地址与模型名在 2026-11-21 对照各家的官方文档核对过（V35），与参考实现不同的几项：
//   deepseek 的模型由 deepseek-chat 改为 deepseek-flash（DeepSeek 的更新日志写明旧名称 2026-07-24 停用，
//   快速开始页的示例用 deepseek-flash）；openai 的模型由 gpt-4.1-mini 改为 gpt-6-luna（gpt-4.1-mini 在模型页上
//   标为 Deprecated，gpt-6-luna 支持 /v1/chat/completions）；moonshot 的模型由 moonshot-v1-8k 改为 kimi-k3
//   （聊天接口的模型枚举里已没有 moonshot-v1 系列，kimi-k3 的上下文是 1M，不再有 8k 不够的问题）。
//   qwen 与 ollama 的地址、模型名仍有效，没有改。
// - resolve：设置与预设合并，检查地址的格式与明文 HTTP 的限制。
// - isLocalHost：http 地址只允许本机与局域网（7.11 节）。
// - keychainAccount：钥匙串里每个预设一个账户名（7.7 节）。

import Foundation

/// 服务预设与接口设置的规则。
public enum TranslationProviders {
    /// 7 个服务预设，顺序与「翻译」页的下拉一致。
    public static let presets: [TranslationProviderPreset] = [
        TranslationProviderPreset(id: .deepseek, displayName: "DeepSeek", kind: .openAICompatible,
                                  baseURL: "https://api.deepseek.com", model: "deepseek-flash", requiresKey: true),
        TranslationProviderPreset(id: .anthropic, displayName: "Claude (Anthropic)", kind: .anthropic,
                                  baseURL: "https://api.anthropic.com", model: "claude-haiku-5-5", requiresKey: true),
        TranslationProviderPreset(id: .openai, displayName: "OpenAI", kind: .openAICompatible,
                                  baseURL: "https://api.openai.com/v1", model: "gpt-6-luna", requiresKey: true),
        TranslationProviderPreset(id: .qwen, displayName: "Qwen (DashScope)", kind: .openAICompatible,
                                  baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus",
                                  requiresKey: true),
        TranslationProviderPreset(id: .moonshot, displayName: "Kimi (Moonshot)", kind: .openAICompatible,
                                  baseURL: "https://api.moonshot.cn/v1", model: "kimi-k3", requiresKey: true),
        TranslationProviderPreset(id: .ollama, displayName: "Ollama", kind: .openAICompatible,
                                  baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b", requiresKey: false),
        // 「自定义」的显示名由界面文字提供（providerCustom）；这里的英文只用于探针与日志。
        TranslationProviderPreset(id: .custom, displayName: "Custom (OpenAI-compatible)", kind: .openAICompatible,
                                  baseURL: "", model: "", requiresKey: false),
    ]

    /// 某个编号的预设。presets 覆盖了全部编号，找不到只会在新增编号而忘了补表时发生，这时回到 custom。
    public static func preset(_ id: TranslationProviderID) -> TranslationProviderPreset {
        presets.first { $0.id == id } ?? presets[presets.count - 1]
    }

    /// 合并设置与预设，得到可用的接口；不能用时给出原因。
    ///
    /// 规则（7.3 节）：
    /// 1. 地址取设置值，为空时取预设地址；模型同理。地址为空是 missingBaseURL，模型为空是 missingModel。
    /// 2. 地址应能解析，协议是 http 或 https，有主机，不带用户名、密码、查询串与片段，否则是 invalidURL。
    /// 3. 协议是 http 而主机不是本机或局域网时是 insecureRemoteHTTP。
    /// 接口种类与是否要 Key 随预设，改了地址也不变。
    public static func resolve(_ settings: TranslationEndpointSettings)
        -> Result<TranslationEndpoint, TranslationEndpointIssue> {
        let preset = preset(settings.provider)
        let customBase = trimmedBaseURL(settings.baseURL)
        let base = customBase.isEmpty ? trimmedBaseURL(preset.baseURL) : customBase
        let customModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = customModel.isEmpty ? preset.model : customModel
        guard !base.isEmpty else { return .failure(.missingBaseURL) }
        guard !model.isEmpty else { return .failure(.missingModel) }
        guard let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            return .failure(.invalidURL)
        }
        if scheme == "http" && !isLocalHost(host) { return .failure(.insecureRemoteHTTP) }
        return .success(TranslationEndpoint(provider: settings.provider, kind: preset.kind, baseURL: url,
                                            model: model, requiresKey: preset.requiresKey))
    }

    /// 去掉首尾空白与末尾的全部 `/`。
    private static func trimmedBaseURL(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// http 地址的主机是否算本机或局域网（7.3 节第 4 条）。
    ///
    /// 算：`localhost`；以 `.local` 结尾；不含 `.` 且不是 IP 的主机名；IPv4 的 127/8、10/8、172.16/12、192.168/16、
    /// 169.254/16；IPv6 的 `::1`、fc00::/7、fe80::/10，以及映射到上述 IPv4 的 `::ffff:a.b.c.d`。
    /// 全是数字或 `0x` 开头的十六进制「主机名」可能被系统当成 IP 解释（如 2130706433），一律不算。
    public static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        // IPv6 的地址可带区域（fe80::1%en0），比较前去掉。
        if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return false }
        if name.contains(":") {
            guard let bytes = ipv6Bytes(name) else { return false }
            return isLocalIPv6(bytes)
        }
        if let octets = ipv4Octets(name) { return isLocalIPv4(octets) }
        if name == "localhost" || name.hasSuffix(".local") { return true }
        if name.contains(".") { return false }
        // 不带点的主机名：排除可能被当成数字地址的写法。
        if name.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
        if name.hasPrefix("0x"), name.dropFirst(2).allSatisfy({ $0.isHexDigit }) { return false }
        return true
    }

    /// 钥匙串里这个服务的账户名，如 `apikey.deepseek`。
    public static func keychainAccount(for provider: TranslationProviderID) -> String {
        "apikey." + provider.rawValue
    }

    // MARK: - IP 地址

    /// 点分十进制的 IPv4 地址的 4 个字节；不是这种写法时为 nil。
    static func ipv4Octets(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        // s_addr 是网络字节序，按内存顺序取出就是 a.b.c.d 的顺序。
        return withUnsafeBytes(of: address.s_addr) { Array($0) }
    }

    /// IPv6 地址的 16 个字节；不是 IPv6 地址时为 nil。
    static func ipv6Bytes(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// IPv4 的回环、私有与链路本地网段。
    static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    /// IPv6 的回环、唯一本地（fc00::/7）与链路本地（fe80::/10）；映射的 IPv4 按 IPv4 的规则。
    static func isLocalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isLocalIPv4(Array(bytes[12..<16]))
        }
        return false
    }
}
