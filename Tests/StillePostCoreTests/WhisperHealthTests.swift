import XCTest
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
}

private final class HealthTranscriber: DictationTranscriber {
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
