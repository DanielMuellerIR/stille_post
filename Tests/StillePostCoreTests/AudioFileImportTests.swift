import XCTest
import CryptoKit
@testable import StillePostCore

final class AudioFileImportTests: XCTestCase {
    @MainActor func testASRFailureKeepsImportMarkerAndRetryFreezesPrivatePolicy() async throws {
        let f = try FileImportFixture(privateText: true); defer { f.dispose() }
        f.transcriber.fails = true
        f.engine.importAudioFile(f.source)
        try await fileWait { f.results.count == 1 && !f.engine.hasInFlightRequests }
        let stored = try XCTUnwrap(try f.history.list().first)
        XCTAssertEqual(stored.audioIsComplete, true)
        XCTAssertTrue(stored.canRetry); XCTAssertEqual(f.waves.count, 1)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        f.transcriber.fails = false
        let gate = FileImportGate(); f.transcriber.gate = gate
        var privateResult: HistoryStore.Entry?
        f.engine.onPrivateRetryResult = { privateResult = $0 }
        let retry = Task { try await f.engine.retry(entry: stored) }
        try await fileWait { f.transcriber.languages.count == 2 }
        var changed = f.config; changed.whisper.language = "en"; changed.history.storeText = true
        f.engine.configure(changed); await gate.open()
        let result = try await retry.value
        XCTAssertEqual(result.rawText, "Teil 2. Teil 3.")
        XCTAssertEqual(f.cleanup.inputs, ["Teil 2. Teil 3."])
        XCTAssertEqual(f.transcriber.languages, ["de", "de", "de"])
        XCTAssertEqual(f.transcriber.wavFileCalls, 0)
        XCTAssertEqual(result.storesText, false); XCTAssertEqual(privateResult?.cleanText, result.cleanText)
        XCTAssertTrue(try f.history.list().isEmpty); XCTAssertTrue(f.waves.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

    @MainActor func testThirtyMinuteRetainedImportRetryUsesBoundedSegmentsAndOneCleanup() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let retained = f.history.newRecordingURL()
        let writer = try WavFileWriter(url: retained)
        let tone = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000) * 0.3) }
        for _ in 0..<1800 { try writer.append(tone) }
        try writer.finish()
        var config = f.config; config.vad.maxSegmentSec = 600; config.vad.paddingSec = 1800
        f.engine.configure(config)
        var original = HistoryStore.Entry(rawText: "", cleanText: "", status: "failed",
            audioFileName: retained.lastPathComponent, durationSec: 1800, audioIsComplete: true)
        original.date = Date(timeIntervalSince1970: 1_700_000_000)
        try f.history.append(original)
        let result = try await f.engine.retry(entry: original)
        XCTAssertEqual(result.status, "ok"); XCTAssertEqual(result.date, original.date)
        XCTAssertGreaterThan(f.transcriber.languages.count, 50)
        XCTAssertLessThanOrEqual(f.transcriber.maximumSamples, 31 * 16000)
        XCTAssertLessThanOrEqual(f.probe.maximumReadSamples, 16384)
        XCTAssertEqual(f.probe.maximumWriteSamples, 0)
        XCTAssertEqual(f.transcriber.wavFileCalls, 0)
        XCTAssertEqual(f.cleanup.inputs.count, 1)
        XCTAssertEqual(f.cleanup.inputs.first, (1...f.transcriber.languages.count).map { "Teil \($0)." }.joined(separator: " "))
        XCTAssertEqual(f.cleanup.warmups, 1); XCTAssertEqual(f.probe.microphoneCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

    @MainActor func testInvalidRetainedAudioCannotBeRevivedByStaleOrManualHistoryUpdates() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let audio = f.history.newRecordingURL()
        try Data(repeating: 65, count: 1024).write(to: audio)
        let entry = HistoryStore.Entry(rawText: "Teiltext 128, nicht 256.", cleanText: "Teiltext 128, nicht 256.", status: "failed",
            audioFileName: audio.lastPathComponent, durationSec: 1, audioIsComplete: true)
        try f.history.append(entry)
        let result = try await f.engine.retry(entry: entry)
        XCTAssertEqual(result.audioIsComplete, false); XCTAssertFalse(result.canRetry)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertEqual(result.rawText, entry.rawText); XCTAssertEqual(result.cleanText, entry.cleanText)
        let other = HistoryStore(baseDir: f.directory.appendingPathComponent("support"))
        let stale = try await other.updateAsync(entry)
        XCTAssertEqual(stale.audioIsComplete, false); XCTAssertFalse(stale.canRetry)
        do { _ = try await f.engine.retry(entry: entry); XCTFail("Veralteter Snapshot hebt Audiosperre auf") }
        catch { XCTAssertTrue(error is AudioImportFailure) }
        XCTAssertTrue(f.transcriber.languages.isEmpty); XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
    }

    @MainActor func testCompletedImportCannotOverwriteOriginalTextAndInvalidityPreservesManualEdits() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let audio = f.history.newRecordingURL(); try f.original.write(to: audio)
        var entry = HistoryStore.Entry(rawText: "Original 128, nicht 256.", cleanText: "Bestätigt 128, nicht 256.", status: "ok",
            audioFileName: audio.lastPathComponent, durationSec: 2.6, audioIsComplete: true)
        entry.originalCleanText = entry.rawText; entry.manualEditCount = 1
        try f.history.append(entry)
        XCTAssertFalse(entry.canRetry)
        do { _ = try await f.engine.retry(entry: entry); XCTFail("Erfolgreichen Rohtext überschrieben") }
        catch { XCTAssertTrue(error is AudioImportFailure) }
        var invalid = entry; invalid.audioIsComplete = false; invalid.errorMessage = "Künstlicher Audiofehler"
        _ = try await f.history.updateAsync(invalid)
        let other = HistoryStore(baseDir: f.directory.appendingPathComponent("support"))
        let stale = try await other.updateAsync(entry)
        XCTAssertEqual(stale.audioIsComplete, false)
        XCTAssertEqual(stale.rawText, entry.rawText); XCTAssertEqual(stale.cleanText, entry.cleanText)
        XCTAssertEqual(stale.originalCleanText, entry.originalCleanText); XCTAssertEqual(stale.manualEditCount, 1)
        XCTAssertEqual(stale.errorMessage, invalid.errorMessage)
        XCTAssertTrue(f.transcriber.languages.isEmpty); XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: audio), f.original)
    }

    @MainActor func testCancellationOfImportRetryKeepsRetainedAudioAndRejectsLateResult() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let audio = f.history.newRecordingURL(); try f.original.write(to: audio)
        let entry = HistoryStore.Entry(rawText: "", cleanText: "", status: "failed",
            audioFileName: audio.lastPathComponent, durationSec: 2.6, audioIsComplete: true)
        try f.history.append(entry)
        let gate = FileImportGate(); f.transcriber.gate = gate
        let retry = Task { try await f.engine.retry(entry: entry) }
        try await fileWait { f.transcriber.languages.count == 1 }
        retry.cancel(); await gate.open()
        do { _ = try await retry.value; XCTFail("Abgebrochene Wiederholung erfolgreich") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: audio), f.original)
        XCTAssertEqual(try f.history.list().first?.status, "failed")
        XCTAssertTrue(f.results.isEmpty)
    }

    @MainActor func testThirtyMinuteImportBoundsReaderAndRequestsAndCleansOrderedTextOnce() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let writer = try WavFileWriter(url: f.source)
        let tone = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16000) * 0.3) }
        for _ in 0..<1800 { try writer.append(tone) }
        try writer.finish()
        let original = try fileDigest(f.source)
        var config = f.config; config.vad.maxSegmentSec = 600; config.vad.paddingSec = 1800
        f.engine.configure(config)
        var progress: [AudioImportProgress] = []
        f.engine.onAudioImportProgress = { value in
            XCTAssertTrue(Thread.isMainThread); progress.append(value)
        }
        f.engine.importAudioFile(f.source)
        // Der 30-Minuten-Dekodierlauf braucht auf geteilten CI-Rechnern mehr Zeit.
        let end = Date().addingTimeInterval(120)
        while f.engine.hasInFlightRequests, Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(f.engine.hasInFlightRequests)
        XCTAssertEqual(f.results.count, 1)
        XCTAssertEqual(f.results.first?.entry?.durationSec ?? 0, 1800, accuracy: 0.01)
        XCTAssertGreaterThan(f.transcriber.languages.count, 50)
        XCTAssertLessThanOrEqual(f.transcriber.maximumSamples, 16000 * 31)
        XCTAssertLessThanOrEqual(f.probe.maximumReadSamples, 16384)
        XCTAssertLessThanOrEqual(f.probe.maximumWriteSamples, 16384)
        let ordered = (1...f.transcriber.languages.count).map { "Teil \($0)." }.joined(separator: " ")
        XCTAssertEqual(f.cleanup.inputs, [ordered])
        XCTAssertEqual(f.results.first?.entry?.rawText, ordered)
        XCTAssertEqual(f.cleanup.warmups, 1)
        XCTAssertEqual(f.probe.microphoneCalls, 0)
        XCTAssertTrue(f.waves.isEmpty)
        XCTAssertEqual(try fileDigest(f.source), original)
        let decoding = progress.filter { $0.stage == .decoding }
        let transcribing = progress.filter { $0.stage == .transcribing }
        XCTAssertFalse(decoding.isEmpty); XCTAssertFalse(transcribing.isEmpty)
        for values in [decoding, transcribing] {
            XCTAssertEqual(values.map(\.audioSeconds), values.map(\.audioSeconds).sorted())
            XCTAssertTrue(values.allSatisfy { (0...1).contains($0.fraction ?? 0) })
        }
        XCTAssertGreaterThan(transcribing.last?.audioSeconds ?? 0, 1600)
        let count = progress.count
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(progress.count, count, "Kein Fortschritt nach Auftragsende")
    }

    @MainActor func testExtendedDurationAndSizeLimitsRejectBeforeAnyASR() async throws {
        for large in [false, true] {
            let f = try FileImportFixture(); defer { f.dispose() }
            if large {
                let handle = try FileHandle(forWritingTo: f.source)
                try handle.truncate(atOffset: UInt64(AudioImportLimits.file.maximumBytes + 1)); try handle.close()
            } else {
                let writer = try WavFileWriter(url: f.source)
                let silence = [Float](repeating: 0, count: 16000)
                for _ in 0..<1801 { try writer.append(silence) }
                try writer.finish()
            }
            let before = try fileDigest(f.source)
            f.engine.importAudioFile(f.source)
            try await fileWait { !f.engine.hasInFlightRequests && f.results.count == 1 }
            XCTAssertTrue(f.transcriber.languages.isEmpty); XCTAssertTrue(f.cleanup.inputs.isEmpty)
            XCTAssertTrue(f.waves.isEmpty); XCTAssertEqual(try fileDigest(f.source), before)
        }
    }

    @MainActor func testFileURLWithForeignAuthorityIsRejectedWithoutOpeningIt() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        f.engine.importAudioFile(try XCTUnwrap(URL(string: "file://remote.invalid/audio.wav")))
        try await fileWait { !f.engine.hasInFlightRequests && f.results.count == 1 }
        XCTAssertTrue(f.waves.isEmpty); XCTAssertTrue(f.transcriber.languages.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty); XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

    @MainActor func testCancelDuringCleanupKeepsSourceAndRejectsLateProgressOrOutput() async throws {
        let f = try FileImportFixture(); defer { f.dispose() }
        let gate = FileImportGate(); f.cleanup.gate = gate
        var progress: [AudioImportProgress] = []
        var stages: [AudioImportStage] = []
        f.engine.onAudioImportProgress = { progress.append($0) }
        f.engine.onAudioImportStage = { stages.append($0) }
        f.engine.importAudioFile(f.source)
        try await fileWait { f.cleanup.inputs.count == 1 }
        XCTAssertEqual(stages, [.decoding, .transcribing, .cleaning])
        f.engine.cancel(); let count = progress.count
        await gate.open()
        try await fileWait { !f.engine.hasInFlightRequests }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(progress.count, count); XCTAssertTrue(f.results.isEmpty)
        XCTAssertTrue(f.waves.isEmpty); XCTAssertEqual(try Data(contentsOf: f.source), f.original)
    }

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
private func fileDigest(_ url: URL) throws -> SHA256.Digest {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while try autoreleasepool(invoking: {
        guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
        hash.update(data: data); return true
    }) {}
    return hash.finalize()
}
private actor FileImportGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { continuations.append($0) } } }
    func open() { opened = true; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}
private final class FileImportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mic = 0, recorder = 0, decoded = false, readSamples = 0, writeSamples = 0
    private var autoStop: Double?
    var microphoneCalls: Int { lock.withLock { mic } }
    var recorders: Int { lock.withLock { recorder } }
    var enteredDecoder: Bool { lock.withLock { decoded } }
    var vadAutoStop: Double? { lock.withLock { autoStop } }
    var maximumReadSamples: Int { lock.withLock { readSamples } }
    var maximumWriteSamples: Int { lock.withLock { writeSamples } }
    func read(_ count: Int) { lock.withLock { readSamples = max(readSamples, count) } }
    func write(_ count: Int) { lock.withLock { writeSamples = max(writeSamples, count) } }
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
            makeSegmenter: { probe.segmenter($0); return FileImportBoundedSegmenter(config: $0, probe: probe) },
            makeWavWriter: { try FileImportBoundedWriter(url: $0, probe: probe, failing: failingWriter) },
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
private final class FileImportBoundedSegmenter: DictationSegmenter {
    let actual: VadSegmenter, probe: FileImportProbe
    var onSegment: ((VadSegmenter.Segment) -> Void)? { get { actual.onSegment } set { actual.onSegment = newValue } }
    var onAutoStop: (() -> Void)? { get { actual.onAutoStop } set { actual.onAutoStop = newValue } }
    var currentLevelDb: Double { actual.currentLevelDb }
    init(config: Config.Vad, probe: FileImportProbe) { actual = VadSegmenter(config: config); self.probe = probe }
    func process(_ samples: [Float]) { probe.read(samples.count); actual.process(samples) }
    func flush() { actual.flush() }
}
private final class FileImportBoundedWriter: DictationWavWriter {
    let actual: WavFileWriter, probe: FileImportProbe
    var url: URL { actual.url }
    init(url: URL, probe: FileImportProbe, failing: Bool) throws {
        self.probe = probe
        actual = try WavFileWriter(url: url, beforeWrite: { if failing && $0 == 1 { throw FileImportTestFailure.write } })
    }
    func append(_ samples: [Float]) throws { probe.write(samples.count); try actual.append(samples) }
    func finish() throws { try actual.finish() }
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
    private var largestSamples = 0
    private var fileCalls = 0
    var fails = false
    var wavFileCalls: Int { lock.withLock { fileCalls } }
    var maximumSamples: Int { lock.withLock { largestSamples } }
    var languages: [String] { lock.withLock { values } }
    var gate: FileImportGate?
    init(language: String) { self.language = language }
    func isReachable() async -> Bool { true }
    func transcribe(samples: [Float]) async throws -> String {
        let number = lock.withLock { values.append(language); largestSamples = max(largestSamples, samples.count); return values.count }
        await gate?.wait()
        if fails { throw FileImportTestFailure.device }
        return "Teil \(number)."
    }
    func transcribe(wavFile: URL) async throws -> String {
        lock.withLock { fileCalls += 1 }; return try await transcribe(samples: [])
    }
}
private final class FileImportTestCleanup: DictationCleanup {
    private let lock = NSLock()
    private var values: [String] = [], warms = 0
    var inputs: [String] { lock.withLock { values } }
    var warmups: Int { lock.withLock { warms } }
    var gate: FileImportGate?
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    func warmUp() { lock.withLock { warms += 1 } }
    func clean(_ rawText: String) async -> CleanupService.Result {
        lock.withLock { values.append(rawText) }
        await gate?.wait()
        return .init(text: rawText, usedFallback: false, fallbackReason: nil, endpoint: nil)
    }
}
