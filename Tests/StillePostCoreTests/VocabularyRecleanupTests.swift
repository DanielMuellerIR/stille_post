import XCTest
@testable import StillePostCore

final class VocabularyRecleanupTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sp-vocabulary-\(UUID())") }
    private func entry() -> HistoryStore.Entry {
        .init(date: Date(timeIntervalSince1970: 1_790_000_000), rawText: "Whis per  128\nGrüße Cafe\u{301}",
              cleanText: "Bisherige Ausgabe", status: "ok", durationSec: 1, cleanupFellBack: true)
    }
    private func result(_ text: String = "Whisper 128 Grüße Café.") -> CleanupService.Result {
        .init(text: text, usedFallback: false, fallbackReason: nil, endpoint: "test @ http://127.0.0.1")
    }

    func testVocabularyDeduplicatesAndRejectsConflictingSpelling() throws {
        let first = try VocabularyRules.adding(term: "CaféKit", variant: nil, to: Config.Cleanup())
        XCTAssertEqual(try VocabularyRules.adding(term: "CaféKit", variant: nil, to: first), first)
        let equivalent = try VocabularyRules.adding(term: "Cafe\u{301}Kit", variant: nil, to: first)
        XCTAssertEqual(equivalent.dictionary.count, first.dictionary.count)
        XCTAssertTrue(equivalent.dictionary.last!.utf8.elementsEqual(first.dictionary.last!.utf8))
        XCTAssertThrowsError(try VocabularyRules.adding(term: "CAFE\u{301}KIT", variant: nil, to: first))
        XCTAssertThrowsError(try VocabularyRules.adding(term: "Name\nAnweisung", variant: nil, to: first))
        XCTAssertThrowsError(try VocabularyRules.adding(term: String(repeating: "a", count: 81), variant: nil, to: first))
    }

    func testVariantsUseOnlyExactWholePhrasesAndNeverChain() throws {
        let config = try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: Config.Cleanup())
        XCTAssertEqual(VocabularyRules.applying(to: "whis per; Whis per. XWhis per Whis perX Whis  per", cleanup: config),
                       "Whisper; Whisper. XWhis per Whis perX Whis  per")
        XCTAssertEqual(try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: config), config)
        var collision = config
        collision.dictionaryVariants.append(.init(source: "Whis per", target: "Whisper"))
        XCTAssertThrowsError(try VocabularyRules.validate(collision))
        XCTAssertEqual(VocabularyRules.applying(to: "Whis per", cleanup: collision), "Whis per")
    }

    func testAmbiguousWordsNumbersVersionsAndNegationsCannotBecomeRules() throws {
        for (source, target) in [("Rack", "RAG"), ("kein Fall", "Keinfall"), ("nicht gut", "Nichtgut"),
                                 ("no thing", "Nothing"), ("the rapy", "Therapy"), ("Whis per2", "Whisper"),
                                 ("v1 2", "v12"), ("git hub", "GitHub2"), ("kleine Katze", "Whisper"),
                                 ("some thing", "Something"), ("man uell", "Manuell"), ("in tern", "Intern")] {
            XCTAssertThrowsError(try VocabularyRules.adding(term: target, variant: source, to: Config.Cleanup()), source)
        }
        let config = try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: Config.Cleanup())
        let protected = "Rack nicht 128 v1.2 keine 256. No translation."
        XCTAssertEqual(VocabularyRules.applying(to: protected, cleanup: config), protected)
    }

    func testFreshVocabularyMergePreservesSettingsAndStaleSettingsCannotEraseIt() throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let file = ConfigFile(url: base.appendingPathComponent("config.json"))
        let initial = Config()
        try file.save(initial)
        var settings = initial; settings.whisper.language = "de"
        try file.save(settings, expected: initial)
        let saved = try file.addVocabulary(term: "Whisper", variant: "Whis per")
        XCTAssertEqual(saved.whisper.language, "de")
        XCTAssertThrowsError(try file.save(settings, expected: settings))
        XCTAssertEqual(try file.load(), saved)
    }

    func testConcurrentConfigFilesMergeVocabularyWithoutLosingTerms() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("config.json")
        try ConfigFile(url: url).save(Config())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for term in ["FirstKit", "SecondKit"] {
                group.addTask { _ = try ConfigFile(url: url).addVocabulary(term: term, variant: nil) }
            }
            try await group.waitForAll()
        }
        let terms = try ConfigFile(url: url).load().cleanup.dictionary
        XCTAssertTrue(terms.contains("FirstKit") && terms.contains("SecondKit"))
    }

    func testMalformedConfigAndInvalidRuleDoNotOverwriteDisk() throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = ConfigFile(url: base.appendingPathComponent("config.json"))
        let malformed = Data("{broken".utf8)
        try malformed.write(to: file.url)
        XCTAssertThrowsError(try file.addVocabulary(term: "NewKit", variant: nil))
        XCTAssertEqual(try Data(contentsOf: file.url), malformed)
        try file.save(Config())
        let before = try Data(contentsOf: file.url)
        XCTAssertThrowsError(try file.addVocabulary(term: "Nothing", variant: "no thing"))
        XCTAssertEqual(try Data(contentsOf: file.url), before)
    }

    func testCleanupSendsPreparedTextButEveryFallbackReturnsOriginalWords() async throws {
        let config = try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: Config.Cleanup())
        for output in ["Whisper bleibt bei 128.", "Frei erfundene völlig andere Antwort."] {
            let transport = VocabularyTransport(output: output)
            let service = CleanupService(config: config, transport: transport)
            let result = await service.clean("Whis per bleibt bei 128.")
            XCTAssertEqual(transport.inputs, ["Whisper bleibt bei 128."])
            if result.usedFallback { XCTAssertEqual(result.text, "Whis per bleibt bei 128.") }
            else { XCTAssertEqual(result.text, output) }
            XCTAssertEqual(result.usedFallback, output.hasPrefix("Frei"))
        }
        let failing = VocabularyTransport(output: "", fails: true)
        let result = await CleanupService(config: config, transport: failing).clean("Whis per bleibt bei 128.")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.text, "Whis per bleibt bei 128.")
    }

    func testRecleanupUsesOneCompleteRawTextAndFreshConfigWithoutAudioOrPersistence() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseDir: base)
        try store.append(entry())
        let snapshot = try XCTUnwrap(store.list().first)
        let file = ConfigFile(url: base.appendingPathComponent("config.json"))
        var config = Config(); config.cleanup.model = "current-model"
        try file.save(config)
        var calls = 0
        let candidate = try await HistoryRecleanup.run(expected: snapshot, history: store, configFile: file) { cleanup, raw in
            calls += 1
            XCTAssertEqual(cleanup.model, "current-model")
            XCTAssertTrue(raw.utf8.elementsEqual(snapshot.rawText.utf8))
            return self.result()
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.list().first, snapshot)
        let saved = try await store.saveRecleanupAsync(candidate.result, durationSec: candidate.durationSec, expected: candidate.expected)
        XCTAssertTrue(saved.rawText.utf8.elementsEqual(snapshot.rawText.utf8))
        XCTAssertEqual(saved.originalCleanText, snapshot.cleanText)
        XCTAssertEqual(saved.resultOrigin, .cleanup)
        XCTAssertEqual(saved.originalResultOrigin, .rawFallback)
        XCTAssertNil(saved.audioFileName)
    }

    func testManualThenRecleanupHasCorrectProvenanceBoundedRevisionsAndLatePipelineProtection() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseDir: base)
        try store.append(entry())
        let initial = try XCTUnwrap(store.list().first)
        var saved = try await store.saveCorrectionAsync("Manuelle Fassung", expected: initial)
        saved = try await store.saveRecleanupAsync(result(), durationSec: 1, expected: saved)
        XCTAssertEqual(saved.resultOrigin, .cleanup)
        XCTAssertEqual(saved.manualEditCount, 1)
        XCTAssertEqual(saved.previousResults?.first?.origin, .manual)
        XCTAssertEqual(saved.previousResults?.first?.text, "Manuelle Fassung")
        for index in 1...4 { saved = try await store.saveRecleanupAsync(result("Fassung \(index)"), durationSec: 1, expected: saved) }
        XCTAssertEqual(saved.previousResults?.count, 3)
        XCTAssertEqual(saved.originalCleanText, initial.cleanText)
        XCTAssertEqual(try store.update(initial).cleanText, saved.cleanText)
        XCTAssertEqual(try store.list().first?.resultOrigin, .cleanup)
    }

    func testRecleanupRejectsDisabledFallbackCancellationAndChangesDuringRequest() async throws {
        for scenario in ["disabled", "fallback", "cancel", "deleted", "changed"] {
            let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
            let store = HistoryStore(baseDir: base)
            try store.append(entry())
            let snapshot = try XCTUnwrap(store.list().first)
            let file = ConfigFile(url: base.appendingPathComponent("config.json"))
            var config = Config(); config.cleanup.enabled = scenario != "disabled"
            try file.save(config)
            var calls = 0
            let task = Task {
                try await HistoryRecleanup.run(expected: snapshot, history: store, configFile: file) { _, _ in
                    calls += 1
                    if scenario == "deleted" { try? store.delete(id: snapshot.id) }
                    if scenario == "changed" { _ = try? await store.saveCorrectionAsync("Andere Fassung", expected: snapshot) }
                    if scenario == "cancel" { try? await Task.sleep(nanoseconds: 100_000_000) }
                    return .init(text: "Neue Fassung", usedFallback: scenario == "fallback", fallbackReason: nil, endpoint: "test")
                }
            }
            if scenario == "cancel" {
                try await Task.sleep(nanoseconds: 20_000_000)
                task.cancel()
            }
            do { _ = try await task.value; XCTFail(scenario) } catch { }
            XCTAssertEqual(calls, scenario == "disabled" ? 0 : 1)
            XCTAssertNotEqual(try store.list().first?.cleanText, "Neue Fassung")
        }
    }

    func testRecleanupCommitRejectsStaleDeletedExpiredPrivateAndFailedEntries() async throws {
        for scenario in ["changed", "deleted", "expired", "private", "failed"] {
            let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
            let store = HistoryStore(baseDir: base)
            var candidate = entry()
            candidate.audioFileName = "fixture.wav"
            if scenario == "private" { candidate.storesText = false }
            if scenario == "failed" { candidate.status = "failed" }
            try store.append(candidate)
            let snapshot = try XCTUnwrap(store.list().first)
            if scenario == "deleted" { try store.delete(id: snapshot.id) }
            if scenario == "changed" { _ = try await store.saveCorrectionAsync("Andere Fassung", expected: snapshot) }
            if scenario == "expired" {
                var expiring = snapshot; expiring.textExpiresAt = Date().addingTimeInterval(-1)
                try store.update(expiring)
            }
            do { _ = try await store.saveRecleanupAsync(result(), durationSec: 1, expected: snapshot); XCTFail(scenario) }
            catch { XCTAssertTrue(error is HistoryStore.PersistenceError, scenario) }
        }
    }

    @MainActor func testLiveVocabularyAppliesToNextDictationWithoutChangingRunningSnapshot() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let config = Config()
        let live = DictationDependencies.live(config: config)
        let transport = VocabularyTransport(output: nil)
        let service = CleanupService(config: config.cleanup, transport: transport)
        let dependencies = DictationDependencies(transcriber: live.transcriber, server: live.server, cleanup: service,
                                                makeRecorder: live.makeRecorder, makeSegmenter: live.makeSegmenter,
                                                makeWavWriter: live.makeWavWriter)
        let engine = DictationEngine(config: config, history: HistoryStore(baseDir: base), dependencies: dependencies)
        let first = expectation(description: "Laufender Auftrag behält Wörterbuch")
        engine.onResult = { result in
            XCTAssertEqual(result.text, "Whis per bleibt bei 128.")
            first.fulfill()
        }
        engine.processForTesting(rawText: "Whis per bleibt bei 128.")
        let vocabulary = try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: config.cleanup)
        engine.configureVocabulary(vocabulary)
        await fulfillment(of: [first], timeout: 2)
        let second = expectation(description: "Nächster Auftrag nutzt Wörterbuch")
        engine.onResult = { result in
            XCTAssertEqual(result.text, "Whisper bleibt bei 128.")
            second.fulfill()
        }
        engine.processForTesting(rawText: "Whis per bleibt bei 128.")
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(transport.inputs, ["Whis per bleibt bei 128.", "Whisper bleibt bei 128."])
        await engine.shutdown().value
    }

    func testBridgeFreezesVocabularyBeforeTranscriptionAndUsesUpdateForNextRequest() async throws {
        let transport = VocabularyTransport(output: nil)
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        let vocabulary = BridgeVocabulary(cleanup: service)
        let started = expectation(description: "Brücken-Whisper läuft")
        let gate = BridgeTranscriptionGate()
        var handlers = BridgeHandlers(transcribe: { _ in
            started.fulfill()
            await gate.wait()
            return "Whis per bleibt bei 128."
        }, cleanup: { text in await service.clean(text) }, cleanupEnabled: true, version: "test")
        handlers.cleanupForRequest = { vocabulary.snapshot() }
        let router = BridgeRouter(handlers: handlers, maxBodyBytes: 1024, tokenProvider: { "synthetic-fixture" })
        let request = BridgeRequest(method: "POST", path: "/v1/dictate", bearerToken: "synthetic-fixture", body: Data([1]))
        let first = Task { await router.respond(to: request) }
        await fulfillment(of: [started], timeout: 2)
        vocabulary.update(try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: Config.Cleanup()))
        await gate.release()
        let firstResponse = await first.value
        XCTAssertEqual(firstResponse.status, 200)
        let next = await router.respond(to: BridgeRequest(method: "POST", path: "/v1/cleanup", bearerToken: "synthetic-fixture",
                                                          body: Data("Whis per bleibt bei 128.".utf8)))
        XCTAssertEqual(next.status, 200)
        XCTAssertEqual(transport.inputs, ["Whis per bleibt bei 128.", "Whisper bleibt bei 128."])
    }
}

private actor BridgeTranscriptionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class VocabularyTransport: CleanupTransport {
    let output: String?
    let fails: Bool
    var inputs: [String] = []
    init(output: String?, fails: Bool = false) { self.output = output; self.fails = fails }
    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        if fails { throw URLError(.cannotConnectToHost) }
        let body: Data
        if probing { body = Data("{}".utf8) }
        else {
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = object["messages"] as! [[String: Any]]
            let input = messages.last!["content"] as! String
            inputs.append(input)
            body = try JSONSerialization.data(withJSONObject: ["message": ["content": output ?? input]])
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func streamLines(for request: URLRequest, freshConnection: Bool) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        if fails { throw URLError(.cannotConnectToHost) }
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        let input = messages.last!["content"] as! String
        inputs.append(input)
        let frame = try JSONSerialization.data(withJSONObject: ["message": ["content": output ?? input], "done": true])
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield(String(decoding: frame, as: UTF8.self))
            continuation.finish()
        }
        return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func sendWarmUp(_ request: URLRequest) {}
}
