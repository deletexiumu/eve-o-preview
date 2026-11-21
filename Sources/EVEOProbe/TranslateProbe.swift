// SPDX-License-Identifier: GPL-3.0-or-later
//
// 探针的 translate 命令（docs/design-intel-translate.md 9.5 节）：向模型服务发一次固定的测试样例
// （`o7, gate is clear, fly safe`），打印状态码、耗时与解析出的译文。
// 用法：EVEOProbe translate [--provider 编号] [--model 模型] [--base-url 地址] [--target 语言] [--dry-run]
// - Key 只取自环境变量 EVEO_TRANSLATION_API_KEY，不读钥匙串（7.7 节）；预设要 Key 而环境变量为空时不发请求，退出码 1。
// - --dry-run 只打印将要发出的请求（地址、请求头的名字、请求体的键与长度），不联网，不打印 Key。
// **注意：** 不带 --dry-run 时向真实的模型服务发请求，会产生费用。实现方不自行运行它，由主会话在用户同意后运行（V36）。
// 只打印测试样例与模型的答复，不读聊天日志。

import Foundation
import EVEOPreviewCore
import EVEOPreviewPlatform

/// translate 命令的实现。
@MainActor enum TranslateProbe {
    /// 执行 translate 命令，返回退出码：成功 0，设置或答复有问题 1，参数不对 2。
    static func run(_ args: [String]) async -> Int32 {
        let known: Set<String> = ["--provider", "--model", "--base-url", "--target"]
        var values: [String: String] = [:]
        var dryRun = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--dry-run" {
                dryRun = true
                index += 1
            } else if known.contains(arg), index + 1 < args.count {
                values[arg] = args[index + 1]
                index += 2
            } else {
                return Probe.usage()
            }
        }
        guard let provider = TranslationProviderID(rawValue: values["--provider"] ?? "deepseek"),
              let target = AppLanguage(rawValue: values["--target"] ?? "zh") else { return Probe.usage() }
        let settings = TranslationEndpointSettings(provider: provider, baseURL: values["--base-url"] ?? "",
                                                   model: values["--model"] ?? "")
        let endpoint: TranslationEndpoint
        switch TranslationProviders.resolve(settings) {
        case .failure(let issue):
            print("接口设置不能用：\(issue)")
            return 1
        case .success(let resolved):
            endpoint = resolved
        }
        print("预设 \(provider.rawValue)，接口 \(endpoint.kind.rawValue)，地址 \(endpoint.baseURL.absoluteString)，"
              + "模型 \(endpoint.model)，目标语言 \(target.rawValue)")
        let environmentKey = ProcessInfo.processInfo.environment["EVEO_TRANSLATION_API_KEY"]
        let apiKey = environmentKey.flatMap { $0.isEmpty ? nil : $0 }
        let content = TranslationPrompt.testContent(target: target)
        let request = TranslationWire.request(endpoint: endpoint, apiKey: apiKey, content: content)
        if dryRun {
            printDryRun(request, hasKey: apiKey != nil)
            return 0
        }
        if endpoint.requiresKey && apiKey == nil {
            print("这个预设要 Key：请设置环境变量 EVEO_TRANSLATION_API_KEY。没有发请求。")
            return 1
        }
        return await send(request, content: content, kind: endpoint.kind)
    }

    /// 打印将要发出的请求：地址、请求头的名字、请求体的键与长度。不打印 Key 与请求头的值。
    private static func printDryRun(_ request: TranslationHTTPRequest, hasKey: Bool) {
        print("（--dry-run：不发请求）")
        print("POST \(request.url.absoluteString)，超时 \(Int(request.timeoutSeconds)) 秒")
        print("请求头：\(request.headers.keys.sorted().joined(separator: "、"))；Key：\(hasKey ? "有" : "无")")
        let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        print("请求体：\(request.body.count) 字节，键 \(object.keys.sorted().joined(separator: "、"))")
    }

    /// 发请求并打印结果。
    private static func send(_ request: TranslationHTTPRequest, content: TranslationPromptContent,
                             kind: TranslationAPIKind) async -> Int32 {
        let started = ContinuousClock.now
        let result = await URLSessionTranslationTransport().send(request)
        let milliseconds = Probe.milliseconds(since: started)
        switch result {
        case .failure(let error):
            print("发送失败：\(error)，耗时 \(milliseconds) 毫秒")
            return 1
        case .success(let response):
            print("状态码 \(response.status)，耗时 \(milliseconds) 毫秒，正文 \(response.body.count) 字节")
            do {
                let text = try TranslationWire.answer(from: response, kind: kind)
                let parsed = try TranslationWire.parse(text, ids: content.ids)
                guard let translated = parsed.values.first else {
                    print("答复里没有译文")
                    return 1
                }
                print("译文：\(translated.text)（原文语言 \(translated.sourceLanguage ?? "?")）")
                return 0
            } catch {
                print("答复不能用：\(error)")
                return 1
            }
        }
    }
}
