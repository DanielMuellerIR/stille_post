import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StillePostCore

final class WhisperHealthTests: XCTestCase {
    func testHealthRequiresStructuredResponseAndMatchingHttpStatus() throws {
        let url = URL(string: "http://127.0.0.1:8181/health")!
        for (status, body, expected) in [
            (200, #"{"status":"ok"}"#, WhisperClient.Health.ready),
            (503, #"{"status":"loading model"}"#, .loading),
            (200, #"{"status":"loading model"}"#, .unexpectedResponse),
            (404, #"{"status":"ok"}"#, .unexpectedResponse),
            (302, #"{"status":"ok"}"#, .unexpectedResponse),
            (200, "<html>unrelated service</html>", .unexpectedResponse),
            (200, #"{"status":"unknown"}"#, .unexpectedResponse)
        ] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            XCTAssertEqual(WhisperClient.health(data: Data(body.utf8), response: response), expected)
        }
    }
    func testExistingLoadingServerIsAwaitedWithAutostartDisabled() async throws {
        var config = Config.Whisper(); config.autostart = false
        config.binaryPath = "/unavailable-synthetic/whisper"; config.modelPath = "/unavailable-synthetic/model"
        let transcriber = HealthTranscriber([.loading, .ready])
        let manager = WhisperServerManager(config: config)
        try await manager.ensureRunning(reachability: transcriber)
        XCTAssertEqual(transcriber.calls, 2)
    }
    func testUnexpectedServiceNeverAttemptsSecondServer() async throws {
        var config = Config.Whisper(); config.autostart = true; config.binaryPath = "/unavailable-synthetic/whisper"
        let manager = WhisperServerManager(config: config)
        do {
            try await manager.ensureRunning(reachability: HealthTranscriber([.unexpectedResponse]))
            XCTFail("Fremder Dienst wurde als Whisper akzeptiert")
        } catch WhisperServerManager.ServerError.unexpectedService {}
    }
    func testLoadingWaitIsCancellable() async throws {
        let manager = WhisperServerManager(config: Config.Whisper())
        let transcriber = HealthTranscriber([.loading])
        let task = Task { try await manager.ensureRunning(reachability: transcriber) }
        for _ in 0..<100 where transcriber.calls == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertGreaterThan(transcriber.calls, 0)
        task.cancel()
        do { try await task.value; XCTFail("Abgebrochener Modellstart läuft weiter") }
        catch is CancellationError {}
    }

    func testConcurrentRequestsShareOneAutostartProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let program = directory.appendingPathComponent("whisper-fixture")
        let markers = program.appendingPathExtension("pid")
        var config = Config.Whisper()
        config.binaryPath = program.path
        config.modelPath = program.path
        config.autostart = true
        let manager = WhisperServerManager(config: config)
        defer {
            manager.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" >> \"$0.pid\"\nwhile [ -f \"$0\" ]; do /bin/sleep 0.05; done\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)

        let transcriber = ConcurrentStartupTranscriber()
        async let first: Void = manager.ensureRunning(reachability: transcriber)
        async let second: Void = manager.ensureRunning(reachability: transcriber)
        _ = try await (first, second)

        let launches = try String(contentsOf: markers, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(launches.count, 1)
    }
}

private actor ConcurrentStartupTranscriber: DictationTranscriber {
    private var firstProbe: CheckedContinuation<Void, Never>?

    func health() async -> WhisperClient.Health {
        if let firstProbe { firstProbe.resume(); self.firstProbe = nil }
        else { await withCheckedContinuation { firstProbe = $0 } }
        return .unavailable
    }

    func isReachable() async -> Bool { true }
    func transcribe(samples: [Float]) async throws -> String { "unused" }
    func transcribe(wavFile: URL) async throws -> String { "unused" }
}

private final class HealthTranscriber: DictationTranscriber, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [WhisperClient.Health]
    private var callCount = 0
    var calls: Int { lock.withLock { callCount } }
    init(_ statuses: [WhisperClient.Health]) { self.statuses = statuses }
    func health() async -> WhisperClient.Health {
        lock.withLock { callCount += 1; return statuses.count > 1 ? statuses.removeFirst() : statuses[0] }
    }
    func isReachable() async -> Bool { false }
    func transcribe(samples: [Float]) async throws -> String { "unused" }
    func transcribe(wavFile: URL) async throws -> String { "unused" }
}

final class WhisperArtifactTests: XCTestCase {
    func testPreservesDictatedParenthesesAndBrackets() {
        let text = "Termin (nur intern) morgen. Bitte [vorher prüfen]."
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts(text), text)
    }

    func testRemovesKnownSoundMarkersWithoutJoiningOrChangingWords() {
        XCTAssertEqual(
            WhisperClient.cleanWhisperArtifacts("[MUSIK] Termin (nur intern) [Applaus] morgen. (Räuspern)"),
            "Termin (nur intern) morgen."
        )
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts("[music] (laughter) [BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts("zwei[Applaus](Music)Wörter"), "zwei Wörter")
        let text = "(über Musik) [Applaus ist optional] (Lachen]"
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts(text), text)
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts("Zeile  eins\n[Musik] Zeile zwei"),
                       "Zeile  eins\n Zeile zwei")
    }
}
