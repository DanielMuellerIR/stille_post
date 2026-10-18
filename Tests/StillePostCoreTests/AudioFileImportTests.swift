import XCTest
@testable import StillePostCore

final class AudioFileImportTests: XCTestCase {
    @MainActor func testImportFreezesPolicyKeepsOriginalAndCleansWholeTextOnce() async throws {
        let f = try FileImportFixture(privateText: true)
        defer { f.dispose() }
        let gate = FileImportGate(); f.server.gate = gate
        f.engine.importAudioFile(f.source)
        try await fileWait { f.server.entered }
        var changed = f.config; changed.whisper.language = "en"; changed.history.storeText = true
        f.engine.configure(changed)
        await gate.open()
        try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
        XCTAssertEqual(f.results[0].entry?.rawText, "Teil 1. Teil 2.")
        XCTAssertEqual(f.results[0].entry?.storesText, false)
        XCTAssertEqual(f.transcriber.languages, ["de", "de"])
        XCTAssertEqual(f.cleanup.inputs, ["Teil 1. Teil 2."])
        XCTAssertEqual(f.cleanup.warmups, 1)
        XCTAssertEqual(f.engine.phaseTimings.transcriptionCount, 2)
        XCTAssertEqual(f.probe.microphoneCalls, 0)
        XCTAssertEqual(f.probe.recorders, 0)
        XCTAssertEqual(f.probe.vadAutoStop, 0)
        XCTAssertTrue(try f.history.list().isEmpty)
        XCTAssertTrue(f.waves.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.original)
        XCTAssertEqual(f.server.stops, 0)
    }

    @MainActor func testCancelWaitsForDecoderAndShutdownWaitsForClosingWork() async throws {
        let gate = FileImportGate(), probe = FileImportProbe()
        let f = try FileImportFixture(probe: probe, beforeChunk: { _ in probe.decodeEntered(); await gate.wait() })
        defer { f.dispose() }
        f.engine.importAudioFile(f.source)
        try await fileWait { probe.enteredDecoder }
        XCTAssertEqual(f.waves.count, 1)
        f.engine.cancel()
        XCTAssertEqual(f.engine.state, .processing)
        XCTAssertEqual(f.waves.count, 1, "Offenen Writer nicht löschen")
        var finished = false
        let shutdown = f.engine.shutdown()
        let observer = Task { @MainActor in await shutdown.value; finished = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(finished)
        await gate.open(); await observer.value
        XCTAssertEqual(f.engine.state, .idle)
        XCTAssertTrue(f.waves.isEmpty)
        XCTAssertTrue(f.results.isEmpty)
        XCTAssertTrue(f.transcriber.languages.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

    @MainActor func testCancelInsideInitialStateCallbackNeverStartsFileWork() async throws {
        let f = try FileImportFixture()
        defer { f.dispose() }
        f.engine.onStateChange = { if $0 == .processing { f.engine.cancel() } }
        f.engine.importAudioFile(f.source)
        try await fileWait { f.engine.state == .idle && !f.engine.hasInFlightRequests }
        XCTAssertTrue(f.waves.isEmpty)
        XCTAssertTrue(f.transcriber.languages.isEmpty)
        XCTAssertTrue(f.results.isEmpty)
    }

    @MainActor func testLateTranscriptionAfterCancelCannotDeliverOrStartAnotherJob() async throws {
        let f = try FileImportFixture()
        defer { f.dispose() }
        let gate = FileImportGate(); f.transcriber.gate = gate
        f.engine.importAudioFile(f.source)
        try await fileWait { !f.transcriber.languages.isEmpty }
        f.engine.cancel(); f.engine.importAudioFile(f.source); f.engine.start()
        XCTAssertEqual(f.transcriber.languages.count, 1)
        XCTAssertEqual(f.probe.microphoneCalls, 0)
        XCTAssertEqual(f.waves.count, 1)
        await gate.open()
        try await fileWait { !f.engine.hasInFlightRequests }
        XCTAssertEqual(f.engine.state, .idle)
        XCTAssertTrue(f.results.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertTrue(f.waves.isEmpty)
    }

    @MainActor func testIncompleteErrorAudioIsKeptPrivateAndCannotBeRetriedViaCore() async throws {
        let f = try FileImportFixture(privateText: true, failingWriter: true)
        defer { f.dispose() }
        f.engine.importAudioFile(f.source)
        try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
        let entry = try XCTUnwrap(try f.history.list().first)
        XCTAssertEqual(entry.audioIsComplete, false)
        XCTAssertEqual(entry.storesText, false)
        XCTAssertFalse(entry.canRetry)
        XCTAssertEqual(entry.rawText, "")
        XCTAssertEqual(f.waves.count, 1)
        var forged = entry; forged.audioIsComplete = true
        do { _ = try await f.engine.retry(entry: forged); XCTFail("Unvollständige Kopie erneut transkribiert") }
        catch { XCTAssertTrue(error is AudioImportFailure) }
        XCTAssertTrue(f.transcriber.languages.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

    @MainActor func testServerFailureRetainsCompleteAudioWithoutCleanup() async throws {
        let f = try FileImportFixture()
        defer { f.dispose() }
        f.server.fails = true
        f.engine.importAudioFile(f.source)
        try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
        let entry = try XCTUnwrap(try f.history.list().first)
        XCTAssertEqual(entry.audioIsComplete, true)
        XCTAssertTrue(entry.canRetry)
        XCTAssertEqual(f.waves.count, 1)
        XCTAssertTrue(f.transcriber.languages.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

    @MainActor func testSizeDurationAndInvalidFormatFailBeforeWhisperAndKeepOriginal() async throws {
        for limits in [AudioImportLimits(maximumBytes: 128, maximumSeconds: 300),
                       AudioImportLimits(maximumBytes: 1024 * 1024, maximumSeconds: 1)] {
            let f = try FileImportFixture()
            f.engine.importAudioFile(f.source, limits: limits)
            try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
            XCTAssertTrue(f.waves.isEmpty)
            XCTAssertTrue(f.transcriber.languages.isEmpty)
            XCTAssertTrue(f.cleanup.inputs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: f.source), f.original)
            f.dispose()
        }
        let f = try FileImportFixture(); defer { f.dispose() }
        let damaged = f.directory.appendingPathComponent("damaged.m4a")
        let bytes = Data(repeating: 65, count: 1024); try bytes.write(to: damaged)
        f.engine.importAudioFile(damaged)
        try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
        XCTAssertTrue(f.waves.isEmpty)
        XCTAssertTrue(f.transcriber.languages.isEmpty)
        XCTAssertEqual(try Data(contentsOf: damaged), bytes)
    }

    @MainActor func testClosingImportKeepsOwnershipUntilDecoderStopsAndDropsPrivatePreview() async throws {
        let gate = FileImportGate(), probe = FileImportProbe()
        let f = try FileImportFixture(privateText: true, probe: probe, beforeChunk: { _ in probe.decodeEntered(); await gate.wait() })
        defer { f.dispose() }
        let session = AudioImportSession(engine: f.engine)
        f.engine.onStateChange = { session.receiveState($0) }
        f.engine.onAudioImportStage = { session.receiveStage($0) }
        f.engine.onResult = { session.receiveResult($0) }
        session.start(file: f.source, configuration: f.config, currentConfiguration: f.config,
                      nextRequestConfiguration: f.config, allowed: true)
        try await fileWait { probe.enteredDecoder }
        session.close()
        XCTAssertTrue(session.isActive)
        XCTAssertTrue(session.owns(f.engine))
        XCTAssertFalse(session.releaseForRegularStart())
        XCTAssertNil(session.result)
        await gate.open()
        try await fileWait { !session.isActive && !f.engine.hasInFlightRequests }
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertNil(session.configuration)
        XCTAssertTrue(session.owns(f.engine))
        XCTAssertTrue(session.releaseForRegularStart())
        let next = FileImportGate(); f.transcriber.gate = next
        f.engine.importAudioFile(f.source)
        try await fileWait { !f.transcriber.languages.isEmpty }
        session.close()
        XCTAssertTrue(f.engine.hasInFlightRequests, "Altes Fenster beendet fremden Folgeauftrag")
        await next.open()
        try await fileWait { !f.engine.hasInFlightRequests }
        XCTAssertNil(session.result)
        XCTAssertTrue(f.waves.isEmpty)
    }

    @MainActor func testPreflightDoesNotReleaseOtherOwnershipBeforeChangedOrBusyRejection() throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let session = AudioImportSession(engine: f.engine)
        var releases = 0
        var changed = f.config; changed.whisper.language = "en"
        session.start(file: f.source, configuration: f.config, currentConfiguration: changed,
            nextRequestConfiguration: f.config, allowed: true, beforeStart: { releases += 1; return true })
        session.start(file: f.source, configuration: f.config, currentConfiguration: f.config,
            nextRequestConfiguration: f.config, allowed: false, beforeStart: { releases += 1; return true })
        XCTAssertEqual(releases, 0)
        XCTAssertFalse(session.ownsCurrentSession)
        XCTAssertFalse(f.engine.hasInFlightRequests)
    }

    func testNonFiniteFloatAudioNeverEscapesDecoder() throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let file = f.directory.appendingPathComponent("non-finite.wav")
        var bytes = WavCodec.wavHeader(dataByteCount: 64)
        bytes[20] = 3; bytes[28] = 0; bytes[29] = 250; bytes[30] = 0; bytes[31] = 0
        bytes[32] = 4; bytes[34] = 32
        for _ in 0..<16 {
            var bits = Float.nan.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: file)
        do {
            let reader = try AudioDecoder.FileReader(url: file, maxSampleCount: 16000)
            while let values = try reader.read() { XCTAssertTrue(values.allSatisfy(\.isFinite)) }
        } catch { XCTAssertTrue(error is AudioDecoder.DecodeError) }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAtomicSourceReplacementIsDetectedBeforeAnyTranscription() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let source = f.source, replacement = f.original + Data("foreign change".utf8)
        let working = f.history.newRecordingURL()
        let work = AudioFileImportWork(source: source, workingURL: working, limits: .shortClip,
            makeWriter: { try WavFileWriter(url: $0) }, beforeChunk: { index in
                if index == 1 { try? replacement.write(to: source, options: .atomic) }
            })
        do { try await work.prepare(); XCTFail("Fremdänderung blieb unbemerkt") }
        catch { guard case AudioImportFailure.fileChanged = error else { return XCTFail("Falscher Fehler: \(error)") } }
        XCTAssertFalse(work.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: working.path))
        XCTAssertEqual(try Data(contentsOf: source), replacement)
    }

    @MainActor func testAacAndAiffImportKeepOriginalBytesAndOneCleanup() async throws {
        let converter = URL(fileURLWithPath: "/usr/bin/afconvert")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: converter.path))
        for (extensionName, arguments) in [("m4a", ["-f", "m4af", "-d", "aac"]),
                                            ("aiff", ["-f", "AIFF", "-d", "BEI16@44100", "-c", "2"])] {
            let f = try FileImportFixture()
            defer { f.dispose() }
            let converted = f.directory.appendingPathComponent("original." + extensionName)
            let process = Process(); process.executableURL = converter
            process.arguments = arguments + [f.source.path, converted.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            guard process.terminationStatus == 0 else { return }
            let before = try Data(contentsOf: converted)
            f.engine.importAudioFile(converted)
            try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
            XCTAssertEqual(f.results[0].entry?.rawText, "Teil 1. Teil 2.")
            XCTAssertEqual(f.cleanup.inputs, ["Teil 1. Teil 2."])
            XCTAssertEqual(f.probe.microphoneCalls, 0)
            XCTAssertTrue(f.waves.isEmpty)
            XCTAssertEqual(try Data(contentsOf: converted), before)
        }
    }

    func testReaderEnforcesActualSampleLimitAndLegacyHistoryKeepsRetry() throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let reader = try AudioDecoder.FileReader(url: f.source, maxSampleCount: 20_000)
        XCTAssertLessThanOrEqual(try XCTUnwrap(reader.read()).count, 16384)
        XCTAssertThrowsError(try reader.read())
        let old = HistoryStore.Entry(rawText: "", cleanText: "", status: "failed", audioFileName: "test.wav", durationSec: 1)
        let decoded = try JSONDecoder().decode(HistoryStore.Entry.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.audioIsComplete)
        XCTAssertTrue(decoded.canRetry)
    }
}

@MainActor private func fileWait(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw FileImportTestFailure.timeout
}
private enum FileImportTestFailure: Error { case device, write, timeout }
private actor FileImportGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { continuations.append($0) } } }
    func open() { opened = true; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}
private final class FileImportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mic = 0, recorder = 0, decoded = false
    private var autoStop: Double?
    var microphoneCalls: Int { lock.withLock { mic } }
    var recorders: Int { lock.withLock { recorder } }
    var enteredDecoder: Bool { lock.withLock { decoded } }
    var vadAutoStop: Double? { lock.withLock { autoStop } }
    func microphone() { lock.withLock { mic += 1 } }
    func recording() { lock.withLock { recorder += 1 } }
    func decodeEntered() { lock.withLock { decoded = true } }
    func segmenter(_ config: Config.Vad) { lock.withLock { autoStop = config.autoStopAfterSilenceSec } }
}
private final class FileImportFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source: URL
    let original: Data
    let history: HistoryStore
    let probe: FileImportProbe
    let server = FileImportTestServer(), cleanup = FileImportTestCleanup(), transcriber = FileImportTestTranscriber(language: "de")
    var config = Config()
    var engine: DictationEngine!
    var results: [DictationResult] = []
    var waves: [URL] { (try? FileManager.default.contentsOfDirectory(at: history.recordingsDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }) ?? [] }
    init(privateText: Bool = false, failingWriter: Bool = false, probe: FileImportProbe = FileImportProbe(),
         beforeChunk: ((Int) async -> Void)? = nil) throws {
        self.probe = probe
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("original.wav")
        let tone = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000) * 0.3) }
        original = WavCodec.wavData(from: tone + Array(repeating: 0, count: 9600) + tone)
        try original.write(to: source)
        history = HistoryStore(baseDir: directory.appendingPathComponent("support"))
        config.history.storeText = !privateText; config.history.audioRetentionDays = 30
        config.cleanup.localOnly = true; config.whisper.language = "de"
        config.vad.minSpeechSec = 0.06; config.vad.minSegmentSec = 0.3
        config.vad.splitAfterSilenceSec = 0.15; config.vad.autoStopAfterSilenceSec = 0.2
        engine = DictationEngine(config: config, history: history, dependencies: .init(
            transcriber: transcriber, server: server, cleanup: cleanup,
            makeRecorder: { _ in probe.recording(); return FileImportNoRecorder() },
            makeSegmenter: { probe.segmenter($0); return VadSegmenter(config: $0) },
            makeWavWriter: { try WavFileWriter(url: $0, beforeWrite: { if failingWriter && $0 == 1 { throw FileImportTestFailure.write } }) },
            makeTranscriber: { FileImportTestTranscriber(language: $0.language) },
            beforeFileDecodeChunk: beforeChunk, requestMicrophoneAccess: { probe.microphone(); return false }))
        engine.onResult = { [weak self] in self?.results.append($0) }
    }
    func dispose() { engine.cancel(); try? FileManager.default.removeItem(at: directory) }
}
private final class FileImportNoRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    func start() throws { throw FileImportTestFailure.device }
    func stop() {}
}
private final class FileImportTestServer: DictationServer {
    private let lock = NSLock()
    private var didEnter = false, stopCount = 0
    var gate: FileImportGate?
    var entered: Bool { lock.withLock { didEnter } }
    var stops: Int { lock.withLock { stopCount } }
    var fails = false
    func ensureRunning(reachability: any DictationTranscriber) async throws {
        lock.withLock { didEnter = true }; await gate?.wait()
        if fails { throw FileImportTestFailure.device }
    }
    func stop() { lock.withLock { stopCount += 1 } }
}
private final class FileImportTestTranscriber: DictationTranscriber {
    let language: String
    private let lock = NSLock()
    private var values: [String] = []
    var languages: [String] { lock.withLock { values } }
    var gate: FileImportGate?
    init(language: String) { self.language = language }
    func isReachable() async -> Bool { true }
    func transcribe(samples: [Float]) async throws -> String {
        let number = lock.withLock { values.append(language); return values.count }
        await gate?.wait()
        return "Teil \(number)."
    }
    func transcribe(wavFile: URL) async throws -> String { try await transcribe(samples: []) }
}
private final class FileImportTestCleanup: DictationCleanup {
    var inputs: [String] = [], warmups = 0
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    func warmUp() { warmups += 1 }
    func clean(_ rawText: String) async -> CleanupService.Result {
        inputs.append(rawText)
        return .init(text: rawText, usedFallback: false, fallbackReason: nil, endpoint: nil)
    }
}
