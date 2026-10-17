import XCTest
@testable import StillePostCore

final class ProfileTests: XCTestCase {
    private func config() -> Config {
        var config = Config()
        config.whisper.language = "de"
        var german = Config.Profile(name: "Deutsch")
        german.language = "de"
        var english = Config.Profile(name: "English")
        english.language = "en"
        english.history = Config.History()
        english.history?.storeText = false
        var technical = Config.Profile(name: "Technik")
        var vocabulary = Config.Cleanup()
        vocabulary.dictionary = ["Whisper"]
        vocabulary.dictionaryVariants = [.init(source: "Whis per", target: "Whisper")]
        technical.vocabulary = Config.Vocabulary(vocabulary)
        config.profiles = [german, english, technical]
        config.defaultProfileID = german.id
        return config
    }

    func testMigrationInheritanceAndStableRoundTrip() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"whisper":{"language":"en"},"cleanup":{"enabled":false},"history":{"storeText":false}}"#.utf8))
        XCTAssertTrue(old.profiles.isEmpty)
        XCTAssertEqual(old.resolvedForRequest(), old)
        var config = config()
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored, config)
        config.selectedProfileID = config.profiles[1].id
        XCTAssertEqual(config.resolvedForRequest().whisper.language, "en")
        XCTAssertFalse(config.resolvedForRequest().history.storeText)
        config.selectedProfileID = config.profiles[2].id
        XCTAssertEqual(config.resolvedForRequest().cleanup.dictionary, ["Whisper"])
        XCTAssertEqual(config.resolvedForRequest().whisper.language, "de")
        config.cleanup.enabled = false
        XCTAssertFalse(config.resolvedForRequest().cleanup.enabled)
        var options = Config.CleanupOptions(config.cleanup)
        options.enabled = true
        config.profiles[2].cleanup = options
        XCTAssertTrue(config.resolvedForRequest().cleanup.enabled)
        XCTAssertEqual(config.resolvedForRequest().cleanup.dictionaryVariants.count, 1)
    }

    func testDeletedAndInvalidReferencesFallBackWithoutCreatingIDs() throws {
        var config = config()
        let standard = config.defaultProfileID
        config.selectedProfileID = UUID()
        XCTAssertEqual(config.activeProfile?.id, standard)
        let normalized = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertNil(normalized.selectedProfileID)
        XCTAssertEqual(normalized.activeProfile?.id, standard)
        config.selectedProfileID = config.profiles[1].id
        config.removeProfile(id: config.profiles[1].id)
        XCTAssertNil(config.selectedProfileID)
        XCTAssertEqual(config.activeProfile?.id, standard)
        config.removeProfile(id: try XCTUnwrap(standard))
        XCTAssertNil(config.defaultProfileID)
        XCTAssertNil(config.activeProfile)
        let malformed = try JSONDecoder().decode(Config.self, from: Data(#"{"selectedProfileID":"invalid","defaultProfileID":"invalid"}"#.utf8))
        XCTAssertNil(malformed.activeProfile)
        let id = UUID()
        let mixed = "{\"whisper\":{\"language\":\"en\"},\"history\":{\"storeText\":false},\"profiles\":[{\"id\":\"invalid\",\"name\":\"Bad\"},{\"id\":\"\(id)\",\"name\":\"Good\"}],\"defaultProfileID\":\"\(id)\"}"
        let recovered = try JSONDecoder().decode(Config.self, from: Data(mixed.utf8))
        XCTAssertEqual(recovered.profiles.map(\.id), [id])
        XCTAssertEqual(recovered.resolvedForRequest().whisper.language, "en")
        XCTAssertFalse(recovered.resolvedForRequest().history.storeText)
        var invalid = self.config()
        invalid.profiles.append(invalid.profiles[0])
        XCTAssertThrowsError(try invalid.validate())
        invalid = self.config()
        invalid.profiles[0].language = "de\r\nInjected"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testScopedVocabularyAndConcurrentSelectionPreserveFreshFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sp-profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ConfigFile(url: directory.appendingPathComponent("config.json"))
        var initial = config()
        initial.selectedProfileID = initial.profiles[2].id
        try file.save(initial)
        let stale = try file.load()
        XCTAssertThrowsError(try file.addVocabulary(term: "SwiftUI", variant: "Swift not", profileID: nil))
        XCTAssertEqual(try file.load(), stale)
        _ = try file.addVocabulary(term: "CustomTerm", variant: nil, profileID: initial.vocabularyProfileID)
        let selected = try file.selectProfile(initial.profiles[1].id)
        XCTAssertTrue(selected.profiles[2].vocabulary!.dictionary.contains("CustomTerm"))
        XCTAssertFalse(selected.cleanup.dictionary.contains("CustomTerm"))
    }

    func testOptimisticProfileEditDoesNotOverwriteParallelVocabulary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sp-profiles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ConfigFile(url: directory.appendingPathComponent("config.json"))
        let initial = config()
        try file.save(initial)
        var stale = try file.load()
        let scope = initial.profiles[2].id
        _ = try file.addVocabulary(term: "SwiftUI", variant: nil, profileID: scope)
        _ = try file.selectProfile(scope)
        stale.profiles[2].name = "Veralteter Entwurf"
        XCTAssertThrowsError(try file.save(stale, expected: initial))
        let fresh = try file.load()
        XCTAssertEqual(fresh.selectedProfileID, scope)
        XCTAssertTrue(fresh.profiles[2].vocabulary!.dictionary.contains("SwiftUI"))
        XCTAssertFalse(fresh.cleanup.dictionaryVariants.contains(.init(source: "Whis per", target: "Whisper")))
        var removed = fresh
        removed.removeProfile(id: scope)
        try file.save(removed, expected: fresh)
        XCTAssertThrowsError(try file.addVocabulary(term: "Gemma", variant: nil, profileID: scope))
    }

    func testConcurrentScopedWritesAndSelectionNeverLoseTerms() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sp-profile-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let initial = config()
        try ConfigFile(url: url).save(initial)
        let scope = initial.profiles[2].id
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            do {
                _ = try ConfigFile(url: url).addVocabulary(term: "Term\(index)", variant: nil, profileID: scope)
                _ = try ConfigFile(url: url).selectProfile(scope)
            } catch { XCTFail("\(error)") }
        }
        let fresh = try ConfigFile(url: url).load()
        XCTAssertEqual(fresh.profiles[2].vocabulary?.dictionary.count, 31)
        XCTAssertEqual(fresh.selectedProfileID, scope)
    }

    func testRequestSnapshotKeepsAllFieldsAndReusesUnchangedServices() async throws {
        var config = config()
        let transport = ProfileTransport()
        let whisper = ProfileTranscriber(language: "de")
        let cleanup = CleanupService(config: config.cleanup, transport: transport)
        var clients = 0
        let requests = DictationRequestStore(config: config, transcriber: whisper, cleanup: cleanup,
            makeTranscriber: { value in clients += 1; return ProfileTranscriber(language: value.language) })
        let first = requests.snapshot()
        requests.configure(config)
        XCTAssertTrue(first.transcriber === requests.snapshot().transcriber)
        XCTAssertTrue(first.cleanup === requests.snapshot().cleanup)
        config.selectedProfileID = config.profiles[1].id
        config.profiles[1].cleanup = Config.CleanupOptions(config.cleanup)
        config.profiles[1].cleanup?.enabled = false
        requests.configure(config)
        let next = requests.snapshot()
        XCTAssertEqual(first.config.whisper.language, "de")
        XCTAssertTrue(first.config.history.storeText)
        XCTAssertTrue(first.config.cleanup.enabled)
        XCTAssertEqual(next.config.whisper.language, "en")
        XCTAssertFalse(next.config.history.storeText)
        XCTAssertFalse(next.config.cleanup.enabled)
        XCTAssertEqual(clients, 1)
        requests.configure(config)
        XCTAssertEqual(clients, 1)
        config.removeProfile(id: try XCTUnwrap(first.config.activeProfile?.id))
        requests.configure(config)
        XCTAssertEqual(first.config.activeProfile?.name, "Deutsch", "Gelöschtes Profil bleibt im gestarteten Auftrag erhalten")
        XCTAssertEqual(requests.snapshot().config.activeProfile?.name, "English")
        _ = await next.cleanup.clean("Whis per bleibt bei 128.")
        XCTAssertTrue(transport.inputs.isEmpty, "Deaktivierte Bereinigung sendet keinen Text")
    }

    @MainActor func testSwitchDuringRecordingAndCleanupOnlyChangesNextRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sp-profile-engine-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = config()
        let recorder = ProfileRecorder(), segmenter = ProfileSegmenter(), server = ProfileServer()
        let transport = ProfileTransport()
        let cleanupEntered = expectation(description: "Gesamtbereinigung läuft")
        let gate = ProfileGate()
        transport.beforeClean = { cleanupEntered.fulfill(); await gate.wait() }
        let languageLog = ProfileLanguageLog()
        let service = CleanupService(config: config.cleanup, transport: transport)
        let engine = DictationEngine(config: config, history: HistoryStore(baseDir: directory), dependencies: .init(
            transcriber: ProfileTranscriber(language: "de", log: languageLog), server: server, cleanup: service,
            makeRecorder: { _ in recorder }, makeSegmenter: { _ in segmenter }, makeWavWriter: { try WavFileWriter(url: $0) },
            makeTranscriber: { ProfileTranscriber(language: $0.language, log: languageLog) }, requestMicrophoneAccess: { true }))
        let recording = expectation(description: "Aufnahme läuft")
        engine.onStateChange = { if $0 == .recording { recording.fulfill() } }
        let starting = expectation(description: "Startkonfiguration vor Mikrofon eingefroren")
        let startGate = ProfileGate()
        engine.onBeforeRecordingStart = { starting.fulfill(); await startGate.wait() }
        engine.start()
        await fulfillment(of: [starting], timeout: 2)
        config.selectedProfileID = config.profiles[1].id
        engine.configure(config)
        XCTAssertEqual(engine.sessionConfiguration.whisper.language, "de")
        await startGate.release()
        await fulfillment(of: [recording], timeout: 2)
        engine.onBeforeRecordingStart = nil
        let completed = expectation(description: "Altes Profil abgeschlossen")
        engine.onResult = { result in
            XCTAssertEqual(result.text, "Whis per bleibt bei 128. Whis per bleibt bei 128.")
            XCTAssertTrue(result.entry?.storesText != false)
            completed.fulfill()
        }
        segmenter.emit()
        config.selectedProfileID = config.profiles[1].id
        engine.configure(config)
        segmenter.emit()
        engine.stop()
        await fulfillment(of: [cleanupEntered], timeout: 2)
        config.selectedProfileID = config.profiles[2].id
        engine.configure(config)
        XCTAssertEqual(engine.sessionConfiguration.activeProfile?.name, "Deutsch")
        await gate.release()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(languageLog.values, ["de", "de"])
        XCTAssertEqual(server.stops, 0)
        XCTAssertEqual(transport.inputs.count, 1, "Alle Segmente ergeben einen Bereinigungsauftrag")
        transport.beforeClean = nil
        let technical = expectation(description: "Technikprofil gilt als Nächstes")
        engine.onResult = { result in
            XCTAssertEqual(result.text, "Whisper bleibt bei 128.")
            technical.fulfill()
        }
        engine.processForTesting(rawText: "Whis per bleibt bei 128.")
        await fulfillment(of: [technical], timeout: 2)
        XCTAssertEqual(transport.inputs.last, "Whisper bleibt bei 128.")
        config.selectedProfileID = config.profiles[1].id
        engine.configure(config)
        let english = expectation(description: "Privates EN-Profil")
        engine.onResult = { result in XCTAssertEqual(result.entry?.storesText, false); english.fulfill() }
        let englishRecording = expectation(description: "EN-Aufnahme läuft")
        engine.onStateChange = { if $0 == .recording { englishRecording.fulfill() } }
        engine.start()
        await fulfillment(of: [englishRecording], timeout: 2)
        segmenter.emit()
        engine.stop()
        await fulfillment(of: [english], timeout: 2)
        XCTAssertEqual(languageLog.values.last, "en")
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("history.json")).contains("The number stays"))
        await engine.shutdown().value
    }

    func testBridgeFreezesLanguageAndEnabledBeforeWaiting() async throws {
        var config = config()
        let service = CleanupService(config: config.cleanup, transport: ProfileTransport())
        let requests = DictationRequestStore(config: config, transcriber: ProfileTranscriber(language: "de"), cleanup: service,
            makeTranscriber: { ProfileTranscriber(language: $0.language) })
        let gate = ProfileGate()
        let entered = expectation(description: "Brückenanfrage angenommen")
        var handlers = BridgeHandlers(transcribe: { _ in "" }, cleanup: { await service.clean($0) }, cleanupEnabled: true, version: "test")
        handlers.requestSnapshot = {
            let snapshot = requests.snapshot()
            return .init(transcribe: { _ in
                entered.fulfill()
                await gate.wait()
                return try await snapshot.transcriber.transcribe(samples: [1])
            }, cleanup: { await snapshot.cleanup.clean($0) }, cleanupEnabled: snapshot.config.cleanup.enabled)
        }
        let router = BridgeRouter(handlers: handlers, maxBodyBytes: 1024, tokenProvider: { "fixture" })
        let first = Task { await router.respond(to: .init(method: "POST", path: "/v1/dictate", bearerToken: "fixture", body: Data([1]))) }
        await fulfillment(of: [entered], timeout: 2)
        config.selectedProfileID = config.profiles[1].id
        config.profiles[1].cleanup = Config.CleanupOptions(config.cleanup)
        config.profiles[1].cleanup?.enabled = false
        requests.configure(config)
        await gate.release()
        let response = await first.value
        XCTAssertEqual(response.status, 200)
        let disabled = await router.respond(to: .init(method: "POST", path: "/v1/cleanup", bearerToken: "fixture", body: Data("Testtext".utf8)))
        XCTAssertEqual(disabled.status, 503)
        let health = await router.respond(to: .init(method: "GET", path: "/v1/health", bearerToken: "fixture"))
        XCTAssertTrue(String(data: health.body, encoding: .utf8)!.contains("false"))
    }

    func testRecleanupUsesFreshActiveProfileAndFreezesItsVocabulary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sp-profile-recleanup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ConfigFile(url: directory.appendingPathComponent("config.json"))
        var config = config()
        config.selectedProfileID = config.profiles[2].id
        try file.save(config)
        let history = HistoryStore(baseDir: directory)
        try history.append(.init(rawText: "Whis per bleibt bei 128.", cleanText: "Alte Ausgabe 128.", status: "ok", durationSec: 1))
        let expected = try XCTUnwrap(history.list().first)
        let candidate = try await HistoryRecleanup.run(expected: expected, history: history, configFile: file) { cleanup, raw in
            XCTAssertEqual(cleanup.dictionary, ["Whisper"])
            _ = try! file.selectProfile(config.profiles[1].id)
            XCTAssertEqual(cleanup.dictionaryVariants.count, 1)
            XCTAssertEqual(raw, expected.rawText)
            return .init(text: "Whisper bleibt bei 128.", usedFallback: false, fallbackReason: nil, endpoint: "fixture")
        }
        XCTAssertEqual(try history.list().first?.cleanText, expected.cleanText, "Vorschau schreibt noch nichts")
        let saved = try await history.saveRecleanupAsync(candidate.result, durationSec: candidate.durationSec, expected: candidate.expected)
        XCTAssertEqual(saved.rawText, expected.rawText)
        XCTAssertEqual(saved.originalCleanText, expected.cleanText)
        XCTAssertEqual(saved.cleanText, "Whisper bleibt bei 128.")
    }

    func testPendingPrivateResultsKeepBothCompletionOrders() {
        for values in [["Neues Diktat", "Alter Retry"], ["Alter Retry", "Neues Diktat"]] {
            var pending = PendingResults<String>()
            XCTAssertTrue(pending.append(values[0]))
            XCTAssertFalse(pending.append(values[1]))
            XCTAssertEqual(pending.current, values[0])
            XCTAssertEqual(pending.finish(), values[1])
            XCTAssertNil(pending.finish())
            XCTAssertTrue(pending.isEmpty)
        }
    }
}

private actor ProfileGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private final class ProfileLanguageLog {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
private final class ProfileTranscriber: DictationTranscriber {
    let language: String
    let log: ProfileLanguageLog
    init(language: String, log: ProfileLanguageLog = ProfileLanguageLog()) { self.language = language; self.log = log }
    func transcribe(samples: [Float]) async throws -> String { log.append(language); return language == "en" ? "The number stays 128." : "Whis per bleibt bei 128." }
    func transcribe(wavFile: URL) async throws -> String { try await transcribe(samples: []) }
    func isReachable() async -> Bool { true }
}
private final class ProfileRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?
    var onFailure: ((Error) -> Void)?
    func start() throws { onSamples?([0.1]) }
    func stop() {}
}
private final class ProfileSegmenter: DictationSegmenter {
    var onSegment: ((VadSegmenter.Segment) -> Void)?
    var onAutoStop: (() -> Void)?
    var currentLevelDb: Double { -20 }
    func process(_ samples: [Float]) {}
    func flush() {}
    func emit() { onSegment?(.init(samples: [1], hadSpeech: true, reason: .pause)) }
}
private final class ProfileServer: DictationServer {
    var stops = 0
    func ensureRunning(reachability: any DictationTranscriber) async throws {}
    func stop() { stops += 1 }
}
private final class ProfileTransport: CleanupTransport {
    private let lock = NSLock()
    private var storage: [String] = []
    var inputs: [String] { lock.withLock { storage } }
    var beforeClean: (() async -> Void)?
    func sendWarmUp(_ request: URLRequest) {}
    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    private func input(_ request: URLRequest) throws -> String {
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let text = messages.last!["content"] as! String
        lock.withLock { storage.append(text) }
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, 16384)
        return text
    }
    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        if probing || request.url!.path.contains("generate") { return (Data("{}".utf8), response(request)) }
        let text = try input(request)
        await beforeClean?()
        return (try JSONSerialization.data(withJSONObject: ["message": ["content": text]]), response(request))
    }
    func streamLines(for request: URLRequest, freshConnection: Bool) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let text = try input(request)
        await beforeClean?()
        let data = try JSONSerialization.data(withJSONObject: ["message": ["content": text], "done": true])
        return (AsyncThrowingStream { $0.yield(String(data: data, encoding: .utf8)!); $0.finish() }, response(request))
    }
}
