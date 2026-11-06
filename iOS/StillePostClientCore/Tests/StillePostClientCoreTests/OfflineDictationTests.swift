import XCTest
@testable import StillePostClientCore

@MainActor final class OfflineDictationTests: XCTestCase {
    private var clip: Recording { Recording(url: URL(fileURLWithPath: "/synthetic.m4a"), duration: 3, bytes: 100) }
    private var credentials: BridgeCredentials {
        BridgeCredentials(configuration: BridgeConfiguration(address: "https://mac.local", fingerprint: String(repeating: "a", count: 64)), token: "fixture-token")
    }

    func testSilenceClicksAndInvalidOrUnboundedSamples() throws {
        XCTAssertTrue(try OfflineSpeech.segments(Array(repeating: 0, count: 32_000)).isEmpty)
        var clicks = Array(repeating: Float(0), count: 32_000)
        for index in [100, 7_000, 22_000] { clicks[index] = 1 }
        XCTAssertTrue(try OfflineSpeech.segments(clicks).isEmpty)
        XCTAssertThrowsError(try OfflineSpeech.segments([.nan]))
        XCTAssertThrowsError(try OfflineSpeech.segments(Array(repeating: 0, count: OfflineSpeech.maxSamples + 1)))
        let shortWord = Array(repeating: Float(0.04), count: 2_400)
        XCTAssertEqual(try OfflineSpeech.segments(shortWord).count, 1)
        let paddedWord = Array(repeating: Float(0), count: 8_000) + shortWord + Array(repeating: Float(0), count: 8_000)
        XCTAssertEqual(try OfflineSpeech.segments(paddedWord).flatMap { $0 }, paddedWord)
        XCTAssertEqual(try OfflineSpeech.segments(Array(repeating: 0.002, count: 2_400)).count, 1)
        var seed: UInt64 = 1729
        let stationaryNoise: [Float] = (0..<32_000).map { _ in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return seed >> 63 == 0 ? -0.02 : 0.02
        }
        XCTAssertTrue(try OfflineSpeech.segments(stationaryNoise).isEmpty)
    }

    func testLongSpeechKeepsOrderAndBoundedWindowsWithoutWordRewriting() throws {
        let samples = (0..<(65 * 16_000)).map { Float($0) / Float(65 * 16_000) * 0.5 + 0.02 }
        let chunks = try OfflineSpeech.segments(samples)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 30 * 16_000 })
        XCTAssertEqual(chunks.flatMap { $0 }, samples)
        XCTAssertEqual(OfflineSpeech.join([" Keine zwölf Kopien ", "not 13 copies"]), "Keine zwölf Kopien not 13 copies.")
    }

    func testExplicitOfflineFlowHasNoBridgeCallsAndDeletesOnlyAfterSuccess() async throws {
        let capture = FakeCapture(), files = FakeFiles(), bridge = TextBridge(), offline = ControlledOffline()
        let session = DictationSession(capture: capture, files: files, bridge: bridge, offline: offline, mode: .offline, language: .en)
        session.record(); try await wait { session.state.phase == .recording }
        session.configure(mode: .mac, language: .de)
        XCTAssertEqual(session.state.mode, .offline)
        session.stop(); XCTAssertEqual(session.state.phase, .ready)
        XCTAssertEqual(offline.calls, 0)
        session.send(credentials: credentials)
        let before = await bridge.audioCalls; XCTAssertEqual(before, 0)
        session.transcribe(); try await wait { offline.calls == 1 }
        XCTAssertEqual(offline.language, .en); XCTAssertNotNil(files.recording)
        offline.finish("No, not thirteen copies.")
        try await wait { session.state.phase == .result }
        XCTAssertEqual(session.state.reply?.origin, "local"); XCTAssertNil(files.recording)
        XCTAssertEqual(files.discards, 1)
        let audio = await bridge.audioCalls, clean = await bridge.cleanCalls
        XCTAssertEqual(audio, 0); XCTAssertEqual(clean, 0)
    }

    func testCancelledNativeWorkBlocksRestartAndIgnoresLateSuccess() async throws {
        let files = FakeFiles(recording: clip), offline = ControlledOffline()
        let session = DictationSession(capture: FakeCapture(), files: files, bridge: TextBridge(), offline: offline, mode: .offline)
        session.transcribe(); try await wait { offline.calls == 1 }
        session.interrupt(); XCTAssertEqual(session.state.phase, .stopping)
        session.transcribe(); session.discard(); session.record()
        XCTAssertEqual(offline.calls, 1); XCTAssertNotNil(files.recording)
        offline.finish("late success")
        try await wait { session.state.phase == .ready }
        XCTAssertEqual(session.state.failure, .interrupted); XCTAssertNil(session.state.reply)
        XCTAssertNotNil(files.recording); XCTAssertEqual(files.discards, 0)
    }

    func testModelFailureAndEmptyResultKeepAudioAndRestartDoesNotProcess() async throws {
        let files = FakeFiles(recording: clip), offline = ControlledOffline()
        let session = DictationSession(capture: FakeCapture(), files: files, bridge: TextBridge(), offline: offline, mode: .offline)
        session.transcribe(); try await wait { offline.calls == 1 }; offline.fail(.integrity)
        try await wait { session.state.phase == .failed }
        XCTAssertEqual(session.state.modelFailure, .integrity); XCTAssertNotNil(files.recording)
        session.transcribe(); try await wait { offline.calls == 2 }; offline.finish(" ")
        try await wait { session.state.phase == .failed }
        XCTAssertEqual(session.state.failure, .noSpeech); XCTAssertEqual(files.discards, 0)
        let reopened = DictationSession(capture: FakeCapture(), files: files, bridge: TextBridge(), offline: offline, mode: .offline)
        XCTAssertEqual(reopened.state.phase, .ready); XCTAssertTrue(reopened.state.recovered)
        XCTAssertEqual(offline.calls, 2)
    }

    func testTextCleanupIsExplicitAndFailureKeepsLocalOriginal() async throws {
        let offline = ControlledOffline(), bridge = TextBridge()
        let session = DictationSession(capture: FakeCapture(), files: FakeFiles(recording: clip), bridge: bridge, offline: offline, mode: .offline)
        session.transcribe(); try await wait { offline.calls == 1 }; offline.finish("Keine dreizehn Kopien.")
        try await wait { session.state.phase == .result }
        await bridge.setFailure(.unavailable)
        session.cleanText(credentials: credentials); try await wait { session.state.failure == .unavailable }
        XCTAssertEqual(session.state.reply?.text, "Keine dreizehn Kopien.")
        await bridge.setFailure(nil)
        session.cleanText(credentials: credentials); try await wait { session.state.reply?.origin == "cleaned" }
        XCTAssertEqual(session.state.localText, "Keine dreizehn Kopien.")
        let texts = await bridge.texts, audio = await bridge.audioCalls
        XCTAssertEqual(texts, ["Keine dreizehn Kopien.", "Keine dreizehn Kopien."]); XCTAssertEqual(audio, 0)
    }

    func testCleanupRequestContainsOnlyBoundedTextAndUsesPinnedTransport() async throws {
        let transport = StubTransport(reply: HTTPReply(status: 200, body: Data(#"{"text":"Keine 13 Kopien.","origin":"cleaned"}"#.utf8)))
        let client = BridgeClient(transport: transport)
        _ = try await client.cleanup("Keine dreizehn Kopien.", credentials: credentials)
        let request = await transport.requests.last!, files = await transport.files
        XCTAssertEqual(request.url?.path, "/v1/cleanup")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain; charset=utf-8")
        XCTAssertEqual(request.httpBody, Data("Keine dreizehn Kopien.".utf8))
        XCTAssertTrue(files.allSatisfy { $0 == nil }); XCTAssertFalse(request.allowsCellularAccess)
        do { _ = try await client.cleanup(String(repeating: "x", count: 65_537), credentials: credentials); XCTFail() }
        catch { XCTAssertEqual(error as? ClientFailure, .textTooLarge) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }

    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Erwarteter Offline-Zustand fehlt"); throw ClientFailure.busy
    }
}

@MainActor private final class ControlledOffline: OfflineDictating {
    var calls = 0
    var language: DictationLanguage?
    private var continuation: CheckedContinuation<String, Error>?
    func transcribe(_ recording: Recording, language: DictationLanguage, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        calls += 1; self.language = language
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ text: String) { continuation?.resume(returning: text); continuation = nil }
    func fail(_ error: LocalModelFailure) { continuation?.resume(throwing: error); continuation = nil }
}

private actor TextBridge: BridgeAccess {
    var audioCalls = 0, cleanCalls = 0
    var texts: [String] = []
    var failure: ClientFailure?
    func setFailure(_ value: ClientFailure?) { failure = value }
    func health(_ credentials: BridgeCredentials) async throws -> BridgeHealth { throw ClientFailure.unavailable }
    func dictate(_ recording: Recording, credentials: BridgeCredentials, progress: @escaping @Sendable (Double) -> Void) async throws -> DictationReply {
        audioCalls += 1; throw ClientFailure.unavailable
    }
    func cleanup(_ text: String, credentials: BridgeCredentials) async throws -> DictationReply {
        cleanCalls += 1; texts.append(text)
        if let failure { throw failure }
        return DictationReply(text: "Keine 13 Kopien.", origin: "cleaned")
    }
}
