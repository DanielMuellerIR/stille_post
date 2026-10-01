import XCTest
@testable import StillePostCore

final class AudioFailureLifecycleTests: XCTestCase {
    @MainActor
    func testDeviceLossCancelsSegmentsAndRetainsWavWithoutDeliveringText() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        let transcribing = expectation(description: "Segment läuft")
        let cancelled = expectation(description: "Segment storniert")
        fixture.transcriber.waitForCancellation = true
        fixture.transcriber.onStart = { transcribing.fulfill() }
        fixture.transcriber.onCancel = { cancelled.fulfill() }
        let saved = expectation(description: "Fehlereintrag gespeichert")
        fixture.history.onChange = { saved.fulfill() }
        await start(fixture)
        fixture.recorder.onSamples?([0.2, 0.1, -0.1])
        fixture.segmenter.onSegment?(VadSegmenter.Segment(samples: [0.2], hadSpeech: true, reason: .pause))
        await fulfillment(of: [transcribing], timeout: 2)
        fixture.recorder.onFailure?(AudioRecorder.RecorderError.recordingInterrupted)
        await fulfillment(of: [saved, cancelled], timeout: 2)

        guard case .error = fixture.engine.state else { return XCTFail("Geräteverlust muss als Fehler stoppen") }
        XCTAssertEqual(fixture.recorder.stopCount, 1)
        XCTAssertEqual(fixture.segmenter.flushCount, 0)
        XCTAssertEqual(fixture.cleanup.calls, 0)
        XCTAssertEqual(fixture.deliveries, 0)
        let entry = try XCTUnwrap(fixture.history.list().first)
        XCTAssertEqual(entry.status, "failed")
        XCTAssertGreaterThanOrEqual(entry.durationSec, 0)
        XCTAssertTrue(entry.rawText.isEmpty)
        let name = try XCTUnwrap(entry.audioFileName)
        let wav = fixture.history.recordingsDir.appendingPathComponent(name)
        XCTAssertGreaterThan(try Data(contentsOf: wav).count, 44)
        fixture.engine.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path), "shutdown erhält die Diagnoseaufnahme")
    }

    @MainActor
    func testFailureImmediatelyBeforeStopCannotEnterSuccessfulProcessing() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        fixture.segmenter.onSegment?(VadSegmenter.Segment(samples: [0.1], hadSpeech: true, reason: .pause))
        fixture.recorder.onFailure?(AudioRecorder.RecorderError.recordingInterrupted)
        fixture.engine.stop()
        await drainMainQueue()
        guard case .error = fixture.engine.state else { return XCTFail("Der Gerätefehler muss dem normalen Stopp vorausgehen") }
        XCTAssertEqual(fixture.segmenter.flushCount, 0)
        XCTAssertEqual(fixture.cleanup.calls, 0)
        XCTAssertEqual(fixture.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.writerURL).path))
    }

    @MainActor
    func testOffThreadFailureImmediatelyBeforeStopCannotEnterSuccessfulProcessing() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        let failure = try XCTUnwrap(fixture.recorder.onFailure)
        // Das Signal ist schon angekommen; seine UI-Arbeit steht aber noch in
        // der Mainqueue. stop() muss trotzdem den Gerätefehler berücksichtigen.
        let emitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            failure(AudioRecorder.RecorderError.recordingInterrupted)
            emitted.signal()
        }
        XCTAssertEqual(emitted.wait(timeout: .now() + 1), .success)
        fixture.engine.stop()
        await drainMainQueue()
        guard case .error = fixture.engine.state else { return XCTFail("Der Gerätefehler muss dem normalen Stopp vorausgehen") }
        XCTAssertEqual(fixture.segmenter.flushCount, 0)
        XCTAssertEqual(fixture.cleanup.calls, 0)
        XCTAssertEqual(fixture.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.writerURL).path))
    }

    @MainActor
    func testOffThreadFailureDuringRecorderStopPreventsSuccessfulProcessing() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        fixture.recorder.failWhileStopping = true
        fixture.engine.stop()
        await drainMainQueue()
        guard case .error = fixture.engine.state else { return XCTFail("Ein Gerätefehler während stop() darf kein Erfolg werden") }
        XCTAssertEqual(fixture.recorder.stopCount, 1)
        XCTAssertEqual(fixture.segmenter.flushCount, 0)
        XCTAssertEqual(fixture.cleanup.calls, 0)
        XCTAssertEqual(fixture.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.writerURL).path))
    }

    @MainActor
    func testNormalStopWriterFailureCancelsPendingSegment() async throws {
        let fixture = try LossFixture(writerFailure: .finish)
        defer { fixture.removeFiles() }
        let transcribing = expectation(description: "Segment läuft")
        let cancelled = expectation(description: "Segment nach Schreibfehler storniert")
        fixture.transcriber.waitForCancellation = true
        fixture.transcriber.onStart = { transcribing.fulfill() }
        fixture.transcriber.onCancel = { cancelled.fulfill() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        fixture.segmenter.onSegment?(VadSegmenter.Segment(samples: [0.1], hadSpeech: true, reason: .pause))
        await fulfillment(of: [transcribing], timeout: 2)
        fixture.engine.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        guard case .error = fixture.engine.state else { return XCTFail("Schreibfehler fehlt") }
        XCTAssertEqual(fixture.cleanup.calls, 0)
        XCTAssertEqual(fixture.deliveries, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.writerURL).path))
    }

    @MainActor
    func testNormalStopStillCleansAllSegmentsExactlyOnce() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        await start(fixture)
        let delivered = expectation(description: "Vollständiger Text ausgeliefert")
        var result: DictationResult?
        fixture.engine.onResult = { result = $0; delivered.fulfill() }
        fixture.recorder.onSamples?([0.1])
        for _ in 0..<2 {
            fixture.segmenter.onSegment?(VadSegmenter.Segment(samples: [0.1], hadSpeech: true, reason: .pause))
        }
        fixture.engine.stop()
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(fixture.cleanup.calls, 1)
        XCTAssertEqual(result?.text, "Testtext Testtext")
        XCTAssertEqual(fixture.segmenter.flushCount, 1)
        XCTAssertEqual(fixture.recorder.stopCount, 1)
        XCTAssertEqual(fixture.engine.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.writerURL).path))
    }

    @MainActor
    func testDuplicateAndStaleFailureCallbacksCannotStopANewRecording() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        let saved = expectation(description: "Genau ein Fehlereintrag")
        fixture.history.onChange = { saved.fulfill() }
        await start(fixture)
        let oldFailure = try XCTUnwrap(fixture.recorder.onFailure)
        let oldAutoStop = try XCTUnwrap(fixture.segmenter.onAutoStop)
        oldFailure(AudioRecorder.RecorderError.recordingInterrupted)
        oldFailure(AudioRecorder.RecorderError.recordingInterrupted)
        await fulfillment(of: [saved], timeout: 2)
        await drainMainQueue()
        XCTAssertEqual(try fixture.history.list().count, 1)
        XCTAssertEqual(fixture.recorder.stopCount, 1)

        await start(fixture)
        oldFailure(AudioRecorder.RecorderError.recordingInterrupted)
        oldAutoStop()
        await drainMainQueue()
        XCTAssertEqual(fixture.engine.state, .recording)
        XCTAssertEqual(fixture.recorder.stopCount, 1)
        XCTAssertEqual(try fixture.history.list().count, 1)
        XCTAssertEqual(fixture.deliveries, 0)
        fixture.engine.cancel()
    }

    @MainActor
    func testWriterFailureRetainsDiagnosticWavAndDoesNotAdvertiseRetry() async throws {
        for failure in [LossWriter.Failure.append, .finish] {
            let fixture = try LossFixture(writerFailure: failure)
            defer { fixture.removeFiles() }
            await start(fixture)
            fixture.recorder.onSamples?([0.1])
            fixture.recorder.onFailure?(AudioRecorder.RecorderError.recordingInterrupted)
            await drainMainQueue()
            guard case .error(let message) = fixture.engine.state else { return XCTFail("Schreibfehler fehlt") }
            let url = try XCTUnwrap(fixture.writerURL)
            XCTAssertTrue(message.contains(url.path))
            XCTAssertTrue(message.contains("Künstlicher Schreibfehler"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(try fixture.history.list().isEmpty)
            XCTAssertEqual(fixture.cleanup.calls, 0)
            XCTAssertEqual(fixture.deliveries, 0)
            fixture.engine.shutdown()
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testRecorderStartFailureRetainsAnyAudioAlreadyWritten() async throws {
        let fixture = try LossFixture()
        defer { fixture.removeFiles() }
        fixture.recorder.failStartAfterSamples = true
        let failed = expectation(description: "Startfehler sichtbar")
        fixture.engine.onStateChange = { if case .error = $0 { failed.fulfill() } }
        fixture.engine.start()
        await fulfillment(of: [failed], timeout: 2)
        let url = try XCTUnwrap(fixture.writerURL)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 44)
        guard case .error(let message) = fixture.engine.state else { return XCTFail("Startfehler fehlt") }
        XCTAssertTrue(message.contains(url.path))
        XCTAssertEqual(fixture.deliveries, 0)
        XCTAssertEqual(fixture.cleanup.calls, 0)
        fixture.engine.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testHistoryFailureNamesRetainedWavWithoutDeliveringText() async throws {
        let fixture = try LossFixture(historyFailure: true)
        defer { fixture.removeFiles() }
        let failed = expectation(description: "Verlaufsfehler mit Dateipfad")
        fixture.engine.onStateChange = { state in
            if case .error(let message) = state, message.contains("Künstlicher Verlaufsfehler") {
                failed.fulfill()
            }
        }
        await start(fixture, preserveStateCallback: true)
        fixture.recorder.onSamples?([0.1])
        fixture.recorder.onFailure?(AudioRecorder.RecorderError.recordingInterrupted)
        await fulfillment(of: [failed], timeout: 2)
        let url = try XCTUnwrap(fixture.writerURL)
        guard case .error(let message) = fixture.engine.state else { return XCTFail("Verlaufsfehler fehlt") }
        XCTAssertTrue(message.contains(url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(fixture.cleanup.calls, 0)
        XCTAssertEqual(fixture.deliveries, 0)
        fixture.engine.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testCancelDuringHistoryWriteRemovesOnlyCancelledText() async throws {
        let entered = expectation(description: "Verlaufs-Write läuft")
        let rolledBack = expectation(description: "Abgebrochener Write zurückgenommen")
        let release = DispatchSemaphore(value: 0)
        let gate = LossWriteGate()
        let fixture = try LossFixture(atomicWrite: { data, url in
            if gate.firstWrite() {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            } else { rolledBack.fulfill() }
            try data.write(to: url, options: .atomic)
        })
        defer { release.signal(); fixture.removeFiles() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        fixture.segmenter.onSegment?(VadSegmenter.Segment(samples: [0.1], hadSpeech: true, reason: .pause))
        fixture.engine.stop()
        await fulfillment(of: [entered], timeout: 2)
        fixture.engine.cancel()
        release.signal()
        await fulfillment(of: [rolledBack], timeout: 2)
        XCTAssertTrue(try fixture.history.list().isEmpty)
        XCTAssertEqual(fixture.deliveries, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.writerURL).path))
    }

    @MainActor
    func testOldSilentWriteCannotClearNewProcessingWav() async throws {
        let entered = expectation(description: "Alter Fehler-Write läuft")
        let release = DispatchSemaphore(value: 0)
        let gate = LossWriteGate()
        let fixture = try LossFixture(atomicWrite: { data, url in
            if gate.firstWrite() {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            try data.write(to: url, options: .atomic)
        })
        defer { release.signal(); fixture.removeFiles() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.history.recordingsDir.path)
        fixture.engine.stop()
        await fulfillment(of: [entered], timeout: 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.history.recordingsDir.path)
        fixture.engine.cancel()
        fixture.transcriber.waitForCancellation = true
        let transcribing = expectation(description: "Neue Transkription läuft")
        fixture.transcriber.onStart = { transcribing.fulfill() }
        await start(fixture)
        fixture.recorder.onSamples?([0.1])
        fixture.segmenter.onSegment?(VadSegmenter.Segment(samples: [0.1], hadSpeech: true, reason: .pause))
        await fulfillment(of: [transcribing], timeout: 2)
        fixture.engine.stop()
        let newWav = try XCTUnwrap(fixture.writerURL)
        release.signal()
        // Die serielle History-Queue hat nach list() auch den alten Write beendet.
        _ = try await Task.detached { try fixture.history.list() }.value
        await drainMainQueue()
        fixture.engine.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: newWav.path))
    }

    @MainActor
    private func start(_ fixture: LossFixture, preserveStateCallback: Bool = false) async {
        let started = expectation(description: "Aufnahme läuft")
        let prior = fixture.engine.onStateChange
        fixture.engine.onStateChange = { state in
            if preserveStateCallback { prior?(state) }
            if state == .recording { started.fulfill() }
        }
        fixture.engine.start()
        await fulfillment(of: [started], timeout: 2)
        fixture.engine.onStateChange = preserveStateCallback ? prior : nil
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class LossFixture {
    let directory: URL
    let history: HistoryStore
    let recorder = LossRecorder()
    let segmenter = LossSegmenter()
    let cleanup = LossCleanup()
    let transcriber = LossTranscriber()
    let engine: DictationEngine
    private let urlBox = LossURLBox()
    var writerURL: URL? { urlBox.url }
    var deliveries = 0

    init(writerFailure: LossWriter.Failure? = nil, historyFailure: Bool = false,
         atomicWrite: ((Data, URL) throws -> Void)? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sp-audio-loss-\(UUID())")
        history = HistoryStore(baseDir: directory) { data, url in
            if historyFailure { throw NSError(domain: "LossTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Künstlicher Verlaufsfehler"]) }
            if let atomicWrite { try atomicWrite(data, url) }
            else { try data.write(to: url, options: .atomic) }
        }
        let recorder = recorder, segmenter = segmenter, urlBox = urlBox
        engine = DictationEngine(config: Config(), history: history, dependencies: DictationDependencies(
            transcriber: transcriber, server: LossServer(), cleanup: cleanup,
            makeRecorder: { _ in recorder }, makeSegmenter: { _ in segmenter },
            makeWavWriter: { url in
                urlBox.url = url
                return try LossWriter(url: url, failure: writerFailure)
            }, requestMicrophoneAccess: { true }
        ))
        engine.onResult = { [weak self] _ in self?.deliveries += 1 }
    }
    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
}
private final class LossURLBox { var url: URL? }
private final class LossRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var stopCount = 0
    var failStartAfterSamples = false
    var failWhileStopping = false
    func start() throws {
        if failStartAfterSamples {
            onSamples?([0.2])
            throw AudioRecorder.RecorderError.recordingInterrupted
        }
    }
    func stop() {
        stopCount += 1
        if failWhileStopping, let failure = onFailure {
            // Der Audiothread meldet den Fehler, während der Hauptthread noch
            // im Geräte-Stopp wartet. Erst danach kehrt stop() zurück.
            let emitted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                XCTAssertFalse(Thread.isMainThread)
                failure(AudioRecorder.RecorderError.recordingInterrupted)
                emitted.signal()
            }
            XCTAssertEqual(emitted.wait(timeout: .now() + 1), .success)
        }
    }
}
private final class LossSegmenter: DictationSegmenter {
    var onSegment: ((VadSegmenter.Segment) -> Void)?
    var onAutoStop: (() -> Void)?
    var currentLevelDb: Double { -20 }
    var flushCount = 0
    func process(_ samples: [Float]) {}
    func flush() { flushCount += 1 }
}
private final class LossTranscriber: DictationTranscriber {
    var waitForCancellation = false
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    func transcribe(samples: [Float]) async throws -> String {
        onStart?()
        if waitForCancellation {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { onCancel?(); throw error }
        }
        return "Testtext"
    }
    func transcribe(wavFile: URL) async throws -> String { "Testtext" }
    func isReachable() async -> Bool { true }
}
private final class LossServer: DictationServer {
    func ensureRunning(reachability: any DictationTranscriber) async throws {}
    func stop() {}
}
private final class LossCleanup: DictationCleanup {
    var onFallbackEndpoint: ((String) -> Void)?
    var onPrimaryRetry: (() -> Void)?
    var calls = 0
    func clean(_ rawText: String) async -> CleanupService.Result {
        calls += 1
        return CleanupService.Result(text: rawText, usedFallback: false, fallbackReason: nil, endpoint: nil)
    }
    func warmUp() {}
}
private final class LossWriter: DictationWavWriter {
    enum Failure { case append, finish }
    let url: URL
    let writer: WavFileWriter
    let failure: Failure?
    init(url: URL, failure: Failure?) throws {
        self.url = url
        self.failure = failure
        writer = try WavFileWriter(url: url)
    }
    func append(_ samples: [Float]) throws {
        if failure == .append { throw writeError }
        try writer.append(samples)
    }
    func finish() throws {
        try writer.finish()
        if failure != nil { throw writeError }
    }
    private var writeError: NSError {
        NSError(domain: "LossTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Künstlicher Schreibfehler"])
    }
}

private final class LossWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    func firstWrite() -> Bool {
        lock.lock(); defer { lock.unlock() }
        writes += 1
        return writes == 1
    }
}
