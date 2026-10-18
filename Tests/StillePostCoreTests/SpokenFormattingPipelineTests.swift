import XCTest
@testable import StillePostCore

final class SpokenFormattingPipelineTests: XCTestCase {
    func testDisabledModeAndLocalFormattingMakeNoNetworkRequest() async throws {
        let transport = FormattingTransport { $0 }
        var config = Config.Cleanup(); config.enabled = false
        let raw = "Eins. Format neuer Absatz Zwei 128, nicht 256."
        let ordinary = await CleanupService(config: config, transport: transport).clean(raw)
        XCTAssertTrue(ordinary.text.contains("Format neuer Absatz")); XCTAssertEqual(ordinary.origin, .raw)
        config.spokenFormatting = true
        let service = CleanupService(config: config, transport: transport)
        config.spokenFormatting = false
        let formatted = await service.clean(raw)
        XCTAssertEqual(formatted.text, "Eins.\n\nZwei 128, nicht 256.")
        XCTAssertEqual(formatted.origin, .formatting); XCTAssertFalse(formatted.usedFallback)
        XCTAssertEqual(transport.posts, 0)
    }

    func testOneWholeTextRequestRestoresLiteralBeforeBothWordChecks() async throws {
        let literal = "„Format neue Zeile, 256 nicht 128“"
        let transport = FormattingTransport { $0.replacingOccurrences(of: literal, with: "„999 wird geändert“") }
        var config = Config.Cleanup(); config.spokenFormatting = true; config.localOnly = true
        let service = CleanupService(config: config, transport: transport); service.notePrimarySuccess()
        let raw = "Eins 128, nicht 256. Format neuer Absatz Zwei 1.2. " + literal
        let result = await service.clean(raw)
        XCTAssertEqual(result.text, "Eins 128, nicht 256.\n\nZwei 1.2. " + literal)
        XCTAssertFalse(result.usedFallback); XCTAssertEqual(result.origin, .cleanup)
        XCTAssertEqual(transport.posts, 1)
        let body = try XCTUnwrap(transport.lastBody)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 16384)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertTrue((body["messages"] as? [[String: String]])?.last?["content"]?.contains(literal) == true)
        XCTAssertFalse(result.text.contains("⟦SP"))
    }

    func testMarkerLossStopsWithoutAnotherEndpointAndKeepsRawMeaning() async throws {
        let transport = FormattingTransport { input in
            let expression = try! NSRegularExpression(pattern: "⟦[^⟧]+⟧")
            guard let first = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return input }
            return (input as NSString).replacingCharacters(in: first.range, with: "")
        }
        var config = Config.Cleanup(); config.spokenFormatting = true
        var fallback = Config.Cleanup.Endpoint(); fallback.ollamaURL = "http://127.0.0.1:29999"
        config.fallbacks = [fallback]
        let service = CleanupService(config: config, transport: transport); service.notePrimarySuccess()
        let result = await service.clean("128, nicht 256. Format neue Zeile Version 1.2 bleibt.")
        XCTAssertTrue(result.usedFallback); XCTAssertEqual(result.origin, .rawFallback)
        XCTAssertEqual(result.text.lowercased(), "128, nicht 256.\nVersion 1.2 bleibt.".lowercased())
        XCTAssertEqual(transport.posts, 1)
    }

    func testFormattingCannotRemoveNegationsOrNumbersThroughMarkerBudget() async throws {
        let transport = FormattingTransport { $0.replacingOccurrences(of: "nicht 256", with: "999") }
        var config = Config.Cleanup(); config.spokenFormatting = true
        let service = CleanupService(config: config, transport: transport); service.notePrimarySuccess()
        let result = await service.clean("Server 128, nicht 256. Format neuer Absatz Version 1.2 bleibt.")
        XCTAssertTrue(result.text.contains("nicht 256")); XCTAssertTrue(result.text.contains("128"))
        XCTAssertTrue(result.text.contains("1.2")); XCTAssertFalse(result.text.contains("999"))
        XCTAssertEqual(transport.posts, 1)
    }

    func testOldConfigsStayDisabledAndProfileInheritanceIsIndependent() throws {
        let id = UUID()
        let old = Data("{\"profiles\":[{\"id\":\"\(id)\",\"name\":\"Alt\"}],\"selectedProfileID\":\"\(id)\"}".utf8)
        var config = try JSONDecoder().decode(Config.self, from: old)
        XCTAssertFalse(config.cleanup.spokenFormatting); XCTAssertNil(config.profiles[0].spokenFormatting)
        XCTAssertEqual(config.profiles[0].id, id)
        config.cleanup.spokenFormatting = true
        let frozen = config.resolvedForRequest()
        XCTAssertTrue(frozen.cleanup.spokenFormatting)
        config.profiles[0].spokenFormatting = false
        XCTAssertFalse(config.resolvedForRequest().cleanup.spokenFormatting)
        XCTAssertTrue(frozen.cleanup.spokenFormatting)
        config.cleanup.spokenFormatting = false; config.profiles[0].spokenFormatting = true
        XCTAssertTrue(config.resolvedForRequest().cleanup.spokenFormatting)
        let malformed = Data("{\"id\":\"\(id)\",\"name\":\"Alt\",\"spokenFormatting\":\"falsch\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(Config.Profile.self, from: malformed).spokenFormatting, false)
        let roundtrip = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundtrip.profiles[0].id, id); XCTAssertEqual(roundtrip, config)
    }

    func testLocalRecleanupRequiresPreviewAndKeepsRawAndOriginalOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = ConfigFile(url: root.appendingPathComponent("config.json"))
        var config = Config(); config.cleanup.enabled = false; config.cleanup.spokenFormatting = true
        try file.save(config)
        let history = HistoryStore(baseDir: root.appendingPathComponent("support"))
        let entry = HistoryStore.Entry(rawText: "Eins. Format neuer Absatz Zwei.", cleanText: "Bisherige Ausgabe.", status: "ok", durationSec: 1, originalOrigin: .raw)
        try history.append(entry)
        let expected = try XCTUnwrap(try history.list().first)
        let candidate = try await HistoryRecleanup.run(expected: expected, history: history, configFile: file)
        XCTAssertEqual(try history.list().first?.cleanText, "Bisherige Ausgabe.")
        XCTAssertEqual(candidate.result.origin, .formatting)
        let saved = try await history.saveRecleanupAsync(candidate.result, durationSec: candidate.durationSec, expected: expected)
        XCTAssertEqual(saved.rawText, expected.rawText); XCTAssertEqual(saved.originalCleanText, "Bisherige Ausgabe.")
        XCTAssertEqual(saved.resultOrigin, .formatting); XCTAssertEqual(saved.originalResultOrigin, .raw)
        XCTAssertEqual(saved.previousResults?.count, 1)
    }

    func testLiveBridgeFreezesLocalFormattingAndHonorsExplicitRaw() async throws {
        var config = Config(); config.cleanup.enabled = false; config.cleanup.spokenFormatting = true
        let handlers = BridgeHandlers.live(config: config, version: "test")
        let frozen = try XCTUnwrap(handlers.requestSnapshot?())
        config.cleanup.spokenFormatting = false
        handlers.updateConfiguration?(config)
        let raw = "One 128, not 256. format new paragraph Version 1.2."
        let completed = await frozen.cleanup(raw)
        XCTAssertTrue(frozen.cleanupEnabled)
        XCTAssertEqual(completed.text, "One 128, not 256.\n\nVersion 1.2.")
        XCTAssertEqual(completed.origin, .formatting)
        XCTAssertFalse(try XCTUnwrap(handlers.requestSnapshot?()).cleanupEnabled)

        config.cleanup.spokenFormatting = true; handlers.updateConfiguration?(config)
        let router = BridgeRouter(handlers: handlers, maxBodyBytes: 1024, tokenProvider: { "fixture" })
        let formatted = await router.respond(to: .init(method: "POST", path: "/v1/cleanup", bearerToken: "fixture", body: Data(raw.utf8)))
        XCTAssertEqual(formatted.status, 200)
        let object = try JSONSerialization.jsonObject(with: formatted.body) as! [String: Any]
        XCTAssertEqual(object["origin"] as? String, "formatting")
        XCTAssertEqual(object["text"] as? String, completed.text)
        let rawHandlers = BridgeHandlers(transcribe: { _ in raw }, cleanup: { _ in
            XCTFail("Ausdrücklicher Rohtextauftrag darf keine Formatierung starten")
            return .init(text: "", usedFallback: true, fallbackReason: nil, endpoint: nil)
        }, cleanupEnabled: true, version: "test")
        let rawRouter = BridgeRouter(handlers: rawHandlers, maxBodyBytes: 1024, tokenProvider: { "fixture" })
        let unchanged = await rawRouter.respond(to: .init(method: "POST", path: "/v1/dictate", query: ["raw":"1"], bearerToken: "fixture", body: Data([1])))
        XCTAssertEqual(unchanged.status, 200)
        let rawObject = try JSONSerialization.jsonObject(with: unchanged.body) as! [String: Any]
        XCTAssertEqual(rawObject["text"] as? String, raw)
        XCTAssertEqual(rawObject["origin"] as? String, "raw")
    }
}

private final class FormattingTransport: CleanupTransport {
    private let change: (String) -> String
    private(set) var posts = 0
    private(set) var lastBody: [String: Any]?
    init(_ change: @escaping (String) -> String) { self.change = change }
    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        (Data("{\"version\":\"test\"}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func streamLines(for request: URLRequest, freshConnection: Bool) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        posts += 1
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]; lastBody = body
        let input = (body["messages"] as! [[String: String]]).last!["content"]!
        let output = change(input)
        let data = try JSONSerialization.data(withJSONObject: ["message":["content":output],"done":true])
        return (AsyncThrowingStream { $0.yield(String(decoding: data, as: UTF8.self)); $0.finish() },
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func sendWarmUp(_ request: URLRequest) {}
}
