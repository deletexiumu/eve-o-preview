// SPDX-License-Identifier: GPL-3.0-or-later
//
// 服务预设与接口设置的解析（docs/macos/design-intel-translate.md 7.3 节，14.1 节 TranslationProvidersTests）：
// 7 个预设都能解析（custom 缺地址除外）；空串回到预设值；带用户名、查询串的地址是 invalidURL；
// 公网的 http 是 insecureRemoteHTTP；isLocalHost 对每一类各一例，另有两个反例。

import Testing
import Foundation
import EVEOPreviewCore

/// 服务预设与 resolve、isLocalHost。
struct TranslationProvidersTests {
    /// 7 个预设各有一项，编号与枚举一一对应。
    @Test func presetsCoverEveryProvider() {
        #expect(TranslationProviders.presets.map(\.id) == TranslationProviderID.allCases)
        #expect(TranslationProviders.preset(.anthropic).kind == .anthropic)
        #expect(TranslationProviders.preset(.ollama).requiresKey == false)
        #expect(TranslationProviders.preset(.deepseek).requiresKey)
    }

    /// 除 custom 外，每个预设用默认设置都能解析；custom 缺地址。
    @Test func everyPresetResolves() throws {
        for preset in TranslationProviders.presets where preset.id != .custom {
            let endpoint = try TranslationProviders.resolve(TranslationEndpointSettings(provider: preset.id)).get()
            #expect(endpoint.baseURL.absoluteString == preset.baseURL)
            #expect(endpoint.model == preset.model)
            #expect(endpoint.kind == preset.kind)
            #expect(endpoint.requiresKey == preset.requiresKey)
        }
        #expect(TranslationProviders.resolve(TranslationEndpointSettings(provider: .custom)) == .failure(.missingBaseURL))
    }

    /// 空串与空白回到预设值；自定义的地址去掉末尾的 `/`；Anthropic 改了地址仍是 Anthropic 接口。
    @Test func emptyValuesFallBackToPreset() throws {
        let blank = TranslationEndpointSettings(provider: .deepseek, baseURL: "  ", model: " ")
        let resolved = try TranslationProviders.resolve(blank).get()
        #expect(resolved.baseURL.absoluteString == "https://api.deepseek.com")
        #expect(resolved.model == TranslationProviders.preset(.deepseek).model)

        let proxy = TranslationEndpointSettings(provider: .anthropic, baseURL: "https://proxy.example.com/v1//",
                                                model: "my-model")
        let custom = try TranslationProviders.resolve(proxy).get()
        #expect(custom.baseURL.absoluteString == "https://proxy.example.com/v1")
        #expect(custom.kind == .anthropic)
        #expect(custom.model == "my-model")
    }

    /// custom 有地址没有模型时是 missingModel。
    @Test func customNeedsModel() {
        let settings = TranslationEndpointSettings(provider: .custom, baseURL: "https://llm.example.com/v1")
        #expect(TranslationProviders.resolve(settings) == .failure(.missingModel))
    }

    /// 带用户名、密码、查询串、片段，协议不对或没有主机时是 invalidURL。
    @Test func invalidURLs() {
        for text in ["https://user:pw@api.example.com", "https://user@api.example.com", "https://api.example.com/v1?x=1",
                     "https://api.example.com/v1#frag", "ftp://api.example.com", "api.example.com", "https://",
                     "not a url"] {
            let settings = TranslationEndpointSettings(provider: .custom, baseURL: text, model: "m")
            #expect(TranslationProviders.resolve(settings) == .failure(.invalidURL), "\(text)")
        }
    }

    /// 公网的 http 被拒绝；本机与局域网的 http 可用。
    @Test func insecureRemoteHTTP() {
        let remote = TranslationEndpointSettings(provider: .custom, baseURL: "http://api.example.com/v1", model: "m")
        #expect(TranslationProviders.resolve(remote) == .failure(.insecureRemoteHTTP))
        let lan = TranslationEndpointSettings(provider: .custom, baseURL: "http://192.168.1.20:8080/v1", model: "m")
        #expect((try? TranslationProviders.resolve(lan).get()) != nil)
        let v6 = TranslationEndpointSettings(provider: .custom, baseURL: "http://[::1]:11434/v1", model: "m")
        #expect((try? TranslationProviders.resolve(v6).get()) != nil)
    }

    /// isLocalHost 的每一类各一例。
    @Test func localHostCategories() {
        let local = ["localhost", "LOCALHOST", "studio.local", "nas", "127.0.0.1", "127.8.9.10", "10.1.2.3",
                     "172.16.0.1", "172.31.255.255", "192.168.0.5", "169.254.10.10", "::1", "[::1]",
                     "fd12:3456::1", "fc00::1", "fe80::1", "fe80::1%en0", "::ffff:192.168.1.1"]
        for host in local { #expect(TranslationProviders.isLocalHost(host), "\(host)") }
    }

    /// 反例：172.32.0.1 不在 172.16/12 里；example.com 是公网域名；另有公网 IP 与像数字地址的主机名。
    @Test func remoteHosts() {
        let remote = ["172.32.0.1", "example.com", "8.8.8.8", "172.15.0.1", "2001:db8::1", "::ffff:8.8.8.8",
                      "2130706433", "0x7f000001", "", "fe00::1"]
        for host in remote { #expect(!TranslationProviders.isLocalHost(host), "\(host)") }
    }

    /// 表意句点等 IDNA 里等同于 `.` 的字符：isLocalHost 先换成 `.` 再判断；百分号编码的写法与非 ASCII 的无点主机名都不算。
    /// resolve 对这些地址给出 insecureRemoteHTTP。
    @Test func ideographicDotsAreNotLocal() {
        for host in ["evil。com", "evil．com", "evil｡com", "evil%E3%80%82com", "evil%2ecom", "家里的电脑"] {
            #expect(!TranslationProviders.isLocalHost(host), "\(host)")
        }
        // 换成 `.` 后仍是本机或局域网的写法照常算。
        #expect(TranslationProviders.isLocalHost("nas。"))
        #expect(TranslationProviders.isLocalHost("studio。local"))
        for url in ["http://evil。com/v1", "http://evil%E3%80%82com/v1", "http://evil．com:8080/v1"] {
            let settings = TranslationEndpointSettings(provider: .custom, baseURL: url, model: "m")
            let result = TranslationProviders.resolve(settings)
            #expect(result == .failure(.insecureRemoteHTTP) || result == .failure(.invalidURL), "\(url)")
            #expect((try? result.get()) == nil, "\(url)")
        }
    }

    /// 钥匙串的账户名。
    @Test func keychainAccounts() {
        #expect(TranslationProviders.keychainAccount(for: .deepseek) == "apikey.deepseek")
        #expect(TranslationProviders.keychainAccount(for: .custom) == "apikey.custom")
    }
}
