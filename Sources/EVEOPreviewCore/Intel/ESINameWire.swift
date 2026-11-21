// SPDX-License-Identifier: GPL-3.0-or-later
//
// ESI 人名核对的请求与答复（docs/design-intel-translate.md 6.10 节，依据 E1～E6）。
// 请求：POST https://esi.evetech.net/universe/ids，不带查询串，请求体是名字的 JSON 数组。6 个请求头：
// Content-Type、Accept、Accept-Language: en、X-Compatibility-Date: 2020-01-01、X-Tenant: tranquility、User-Agent。
// User-Agent 里只有应用名、版本与项目地址，不写邮箱、角色名或任何能认出用户的内容。
// batches 保证每组不为空、各项的比较键互不相同、每项 1～100 个字符：任一条不满足，ESI 返回 400 并扣错误额度（E5）。
//
// 答复：
// | 状态码       | 结果                                                                         |
// | 200         | 解析：角色只从 characters 取；同名的游戏对象存在时是 ambiguous                  |
// | 420、429    | rateLimited：先取 retry-after，再取 x-esi-error-limit-reset，都没有时 60，夹到 5～600 |
// | 408、5xx    | server                                                                       |
// | 3xx 与其他 4xx | rejected：请求本身有问题，不重试                                           |
// alliances、corporations 与 agents 不读：它们按简称匹配，返回的名称与请求对不上（E4）。
// 名字是消息正文的一部分，本文件不写日志。

import Foundation

/// 一次核对请求的内容，交给 Platform 用 URLSession 发出。
public struct ESINameRequest: Sendable, Equatable {
    /// 请求地址。
    public var url: URL
    /// 请求头。
    public var headers: [String: String]
    /// 请求体：名字的 JSON 数组。
    public var body: Data
    /// 超时秒数。
    public var timeoutSeconds: Double

    /// 用各字段建请求。
    public init(url: URL, headers: [String: String], body: Data, timeoutSeconds: Double) {
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

/// ESI 人名核对的写法。
public enum ESINameWire {
    /// 接口地址。
    public static let endpoint = "https://esi.evetech.net/universe/ids"
    /// `X-Compatibility-Date` 的值；接口描述里只有这一个可选值（E1）。
    public static let compatibilityDate = "2020-01-01"
    /// 一次请求至多几个名字。
    public static let maxNamesPerRequest = 500
    /// 每个名字至多几个字符。
    public static let maxNameLength = 100
    /// 超时秒数。
    public static let timeoutSeconds = 10.0
    /// 答复正文的上限；超过时是 network("response too large")。
    public static let maxResponseBytes = 1_048_576
    /// 被限流时的等待秒数的范围与默认值。
    static let retryRange: ClosedRange<Double> = 5...600
    static let defaultRetry = 60.0

    /// User-Agent：应用名、版本与项目地址。
    public static func userAgent(appVersion: String) -> String {
        "EVE-O-Preview-macOS/\(appVersion) (+https://github.com/deletexiumu/eve-o-preview-macos)"
    }

    /// 把名字整理成可以发送的几组：连续的空白并成一个空格，去掉空的与超过 100 个字符的，按比较键去重，
    /// 每组至多 500 个。输入为空时没有组。
    public static func batches(_ names: [String]) -> [[String]] {
        var seen: Set<String> = []
        var accepted: [String] = []
        for raw in names {
            let name = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !name.isEmpty, name.count <= maxNameLength,
                  seen.insert(PilotLookupAnswer.key(for: name)).inserted else { continue }
            accepted.append(name)
        }
        return stride(from: 0, to: accepted.count, by: maxNamesPerRequest).map { start in
            Array(accepted[start..<min(start + maxNamesPerRequest, accepted.count)])
        }
    }

    /// 一次请求的内容。names 应已经过 batches 整理。
    public static func request(names: [String], appVersion: String) -> ESINameRequest {
        // [String] 的 JSON 编码不会失败；万一失败，发空数组会得到 400（rejected），不会静默丢名字。
        let body = (try? JSONSerialization.data(withJSONObject: names, options: [])) ?? Data("[]".utf8)
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Accept-Language": "en",
            "X-Compatibility-Date": compatibilityDate,
            "X-Tenant": "tranquility",
            "User-Agent": userAgent(appVersion: appVersion),
        ]
        // endpoint 是常量，URL(string:) 不会失败。
        return ESINameRequest(url: URL(string: endpoint)!, headers: headers, body: body,
                              timeoutSeconds: timeoutSeconds)
    }

    /// 把答复换成结果。headers 的键是小写。names 是这次请求发出的名字，每个名字在结果里各有一项。
    public static func answer(status: Int, headers: [String: String], body: Data,
                              names: [String]) -> Result<PilotLookupAnswer, PilotLookupFailure> {
        switch status {
        case 200:
            break
        case 420, 429:
            return .failure(.rateLimited(retryAfter: retrySeconds(headers)))
        case 408, 500...599:
            return .failure(.server(status: status))
        default:
            return .failure(.rejected(status: status))
        }
        guard body.count <= maxResponseBytes else { return .failure(.network("response too large")) }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let root = object as? [String: Any] else { return .failure(.malformedAnswer) }
        // 角色表：比较键 → (ID, ESI 的写法)。
        var characters: [String: (id: Int, name: String)] = [:]
        guard let characterItems = items(root["characters"]) else { return .failure(.malformedAnswer) }
        for item in characterItems {
            guard let name = item["name"] as? String, let id = integer(item["id"]) else { continue }
            characters[PilotLookupAnswer.key(for: name)] = (id, name)
        }
        // 游戏对象：同名时消息里指的多半是它（6.10 节第 4 条的 ambiguous）。
        var objects: Set<String> = []
        for category in ["inventory_types", "systems", "constellations", "regions", "stations", "factions"] {
            guard let list = items(root[category]) else { return .failure(.malformedAnswer) }
            for item in list {
                if let name = item["name"] as? String { objects.insert(PilotLookupAnswer.key(for: name)) }
            }
        }
        var outcomes: [String: PilotLookupOutcome] = [:]
        for name in names {
            let key = PilotLookupAnswer.key(for: name)
            if let character = characters[key] {
                outcomes[key] = objects.contains(key) ? .ambiguous
                    : .matched(characterID: character.id, name: character.name)
            } else {
                outcomes[key] = .notFound
            }
        }
        return .success(PilotLookupAnswer(outcomes: outcomes,
                                          errorLimitRemain: headerInt(headers, "x-esi-error-limit-remain"),
                                          errorLimitReset: headerInt(headers, "x-esi-error-limit-reset")))
    }

    // MARK: - 内部

    /// 被限流时等多少秒：retry-after，没有时 x-esi-error-limit-reset，都没有时 60，夹到 5～600。
    static func retrySeconds(_ headers: [String: String]) -> Double {
        let raw = headers["retry-after"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            ?? headers["x-esi-error-limit-reset"].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            ?? defaultRetry
        let value = raw.isFinite ? raw : defaultRetry
        return min(max(value, retryRange.lowerBound), retryRange.upperBound)
    }

    /// 一个类别的各项：类别缺失时是空数组（没有命中的类别不出现，E2）；不是对象数组时返回 nil。
    private static func items(_ value: Any?) -> [[String: Any]]? {
        guard let value else { return [] }
        guard let array = value as? [Any] else { return nil }
        return array.compactMap { $0 as? [String: Any] }
    }

    /// JSON 里的整数（JSONSerialization 给的是 NSNumber）；带小数或不是数时为 nil。
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) < 1e15 else { return nil }
        return number.intValue
    }

    /// 答复头里的整数；没有或不是整数时为 nil。
    private static func headerInt(_ headers: [String: String], _ name: String) -> Int? {
        headers[name].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
