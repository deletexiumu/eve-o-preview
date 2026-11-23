// SPDX-License-Identifier: GPL-3.0-or-later
//
// ESI 人名核对的请求与答复的测试（docs/macos/design-intel-translate.md 6.10 节、14.1 节）。
// 人名是虚构的；答复的结构按 E2～E5 手写，不联网。

import Testing
import Foundation
@testable import EVEOPreviewCore

@Suite struct ESINameWireTests {
    /// 把 JSON 文本当作 200 的答复解析。
    private func parse(_ json: String, names: [String], headers: [String: String] = [:])
        -> Result<PilotLookupAnswer, PilotLookupFailure> {
        ESINameWire.answer(status: 200, headers: headers, body: Data(json.utf8), names: names)
    }

    /// 取成功的结果；失败时记一条失败的期望。
    private func outcomes(_ result: Result<PilotLookupAnswer, PilotLookupFailure>) -> [String: PilotLookupOutcome] {
        guard case .success(let answer) = result else {
            Issue.record("应当成功：\(result)")
            return [:]
        }
        return answer.outcomes
    }

    // MARK: - 请求

    @Test func request() throws {
        let request = ESINameWire.request(names: ["Kael Doran", "Mira Voss"], appVersion: "1.2.0")
        #expect(request.url.absoluteString == "https://esi.evetech.net/universe/ids")
        #expect(request.url.query == nil)
        #expect(request.headers == [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Accept-Language": "en",
            "X-Compatibility-Date": "2020-01-01",
            "X-Tenant": "tranquility",
            "User-Agent": "EVE-O-Preview-macOS/1.2.0 (+https://github.com/deletexiumu/eve-o-preview)",
        ])
        let body = try JSONSerialization.jsonObject(with: request.body) as? [String]
        #expect(body == ["Kael Doran", "Mira Voss"])
        #expect(request.timeoutSeconds == 10)
    }

    @Test func batches() {
        #expect(ESINameWire.batches([]).isEmpty)
        let long = String(repeating: "a", count: 101)
        #expect(ESINameWire.batches(["", "  ", long, "Kael  Doran", "kael doran", "Mira"]) == [["Kael Doran", "Mira"]])
        let many = (0..<501).map { "Name\($0)" }
        let groups = ESINameWire.batches(many)
        #expect(groups.map(\.count) == [500, 1])
        #expect(ESINameWire.batches([String(repeating: "b", count: 100)]).first?.first?.count == 100)
    }

    // MARK: - 200 的答复

    @Test func charactersMatchCaseInsensitively() {
        let json = """
        {"characters":[{"id":90000001,"name":"Kael Doran"}],
         "alliances":[{"id":99000001,"name":"Something Else"}]}
        """
        let result = outcomes(parse(json, names: ["kael DORAN", "Mira Voss"]))
        #expect(result["kael doran"] == .matched(characterID: 90_000_001, name: "Kael Doran"))
        #expect(result["mira voss"] == .notFound)
        #expect(result.count == 2)
    }

    @Test func gameObjectsMakeAmbiguous() {
        let json = """
        {"characters":[{"id":1,"name":"STABBER"},{"id":2,"name":"Veldspar"}],
         "inventory_types":[{"id":622,"name":"Stabber"},{"id":1230,"name":"Veldspar"}]}
        """
        let result = outcomes(parse(json, names: ["Stabber", "Veldspar"]))
        #expect(result["stabber"] == .ambiguous)
        #expect(result["veldspar"] == .ambiguous)
    }

    @Test func emptyAnswerAndIgnoredCategories() {
        #expect(outcomes(parse("{}", names: ["Kael Doran"])) == ["kael doran": .notFound])
        // corporations 里名称对不上的项与请求以外的角色都忽略。
        let json = """
        {"corporations":[{"id":5,"name":"Kael Doran Corp"}],"characters":[{"id":3,"name":"Someone"}]}
        """
        #expect(outcomes(parse(json, names: ["Kael Doran"])) == ["kael doran": .notFound])
    }

    @Test func malformedBodies() {
        #expect(parse("[]", names: ["a"]) == .failure(.malformedAnswer))
        #expect(parse("not json", names: ["a"]) == .failure(.malformedAnswer))
        #expect(parse("{\"characters\": 5}", names: ["a"]) == .failure(.malformedAnswer))
        let huge = Data(repeating: 0x20, count: ESINameWire.maxResponseBytes + 1)
        #expect(ESINameWire.answer(status: 200, headers: [:], body: huge, names: ["a"])
                == .failure(.network("response too large")))
    }

    @Test func errorLimitHeaders() {
        let headers = ["x-esi-error-limit-remain": "98", "x-esi-error-limit-reset": "42"]
        guard case .success(let answer) = parse("{}", names: ["a"], headers: headers) else {
            Issue.record("应当成功")
            return
        }
        #expect(answer.errorLimitRemain == 98)
        #expect(answer.errorLimitReset == 42)
        guard case .success(let bare) = parse("{}", names: ["a"], headers: ["x-esi-error-limit-remain": "x"]) else {
            Issue.record("应当成功")
            return
        }
        #expect(bare.errorLimitRemain == nil && bare.errorLimitReset == nil)
    }

    // MARK: - 其他状态码

    @Test func rateLimits() {
        func retry(_ status: Int, _ headers: [String: String]) -> Result<PilotLookupAnswer, PilotLookupFailure> {
            ESINameWire.answer(status: status, headers: headers, body: Data(), names: ["a"])
        }
        #expect(retry(429, ["retry-after": "30"]) == .failure(.rateLimited(retryAfter: 30)))
        #expect(retry(420, ["x-esi-error-limit-reset": "45"]) == .failure(.rateLimited(retryAfter: 45)))
        #expect(retry(420, [:]) == .failure(.rateLimited(retryAfter: 60)))
        #expect(retry(429, ["retry-after": "1"]) == .failure(.rateLimited(retryAfter: 5)))
        #expect(retry(429, ["retry-after": "9999"]) == .failure(.rateLimited(retryAfter: 600)))
    }

    @Test func statusClasses() {
        func classify(_ status: Int) -> Result<PilotLookupAnswer, PilotLookupFailure> {
            ESINameWire.answer(status: status, headers: [:], body: Data("{}".utf8), names: ["a"])
        }
        #expect(classify(503) == .failure(.server(status: 503)))
        #expect(classify(408) == .failure(.server(status: 408)))
        #expect(classify(400) == .failure(.rejected(status: 400)))
        #expect(classify(302) == .failure(.rejected(status: 302)))
        #expect(classify(404) == .failure(.rejected(status: 404)))
    }
}
