import XCTest
@testable import StillePostCore

final class PauseResumeTests: XCTestCase {
    @MainActor
    func testCancelledModelPreparationCannotOpenMicrophoneOrCreateWav() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let gate = PauseGate()
        var entered = false
        f.beforeSegmenter = { entered = true; await gate.wait() }
        f.engine.start()
        try await waitUntil { entered }
        f.engine.cancel()
        await gate.open()
        try await waitUntil { !f.segmenters.isEmpty }
        XCTAssertEqual(f.engine.state, .idle)
        XCTAssertTrue(f.recorders.isEmpty)
        XCTAssertNil(f.wavURL)
        XCTAssertTrue(f.results.isEmpty)
    }

    @MainActor
    func testVadSelectionIsFrozenAcrossPauseAndResume() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        f.config.vad.detector = .silero
        f.engine.configure(f.config)
        try await f.start()
        f.feed(0.1, count: 8000)
        f.engine.pause()
        var changed = f.config
        changed.vad.detector = .rms
        f.engine.configure(changed)
        f.engine.resume()
        try await waitUntil { f.engine.state == .recording }
        XCTAssertEqual(f.segmenterConfigurations.map(\.detector), [.silero, .silero])
        f.engine.cancel()
    }

    @MainActor
    func testThreePhasesKeepOrderOneWavOneCleanupAndFrozenPolicy() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let first = PauseGate()
        f.transcriber.firstGate = first
        try await f.start()
        let oldSamples = try XCTUnwrap(f.recorders[0].onSamples)
        let oldFailure = try XCTUnwrap(f.recorders[0].onFailure)
        let oldAutoStop = try XCTUnwrap(f.segmenters[0].onAutoStop)
        f.feed(0.1, count: 8_000)
        f.engine.pause()
        XCTAssertEqual(f.engine.state, .paused)
        XCTAssertTrue(f.engine.hasInFlightRequests)
        XCTAssertEqual(f.recorders[0].stops, 1)
        XCTAssertEqual(f.engine.recordingDuration, 0.5)
        oldSamples(Array(repeating: 0.9, count: 16_000))
        oldFailure(PauseError.device)
        oldAutoStop()
        await Task.yield()
        XCTAssertEqual(f.engine.state, .paused)
        XCTAssertEqual(f.engine.recordingDuration, 0.5)
        var changed = f.config
        changed.whisper.language = "en"
        changed.cleanup.localOnly = false
        changed.history.storeText = false
        f.engine.configure(changed)
        f.engine.resume()
        try await waitUntil { f.engine.state == .recording }
        oldSamples(Array(repeating: 0.9, count: 16_000))
        oldFailure(PauseError.device); oldAutoStop()
        f.feed(0.2, count: 4_000)
        f.engine.pause()
        f.engine.resume()
        try await waitUntil { f.engine.state == .recording }
        f.feed(0.3, count: 12_000)
        f.engine.pause()
        XCTAssertEqual(f.engine.recordingDuration, 1.5)
        XCTAssertEqual(f.cleanup.inputs, [])
        XCTAssertEqual(f.cleanup.warmups, 1)
        XCTAssertEqual(f.server.stops, 0)
        XCTAssertEqual(f.engine.sessionConfiguration.whisper.language, "de")
        XCTAssertTrue(f.engine.sessionConfiguration.cleanup.localOnly)
        let wav = try Data(contentsOf: XCTUnwrap(f.wavURL))
        XCTAssertEqual(wav.count, 44 + 24_000 * 2)
        func sample(_ index: Int) -> Int16 {
            let low = UInt16(wav[44 + index * 2]), high = UInt16(wav[45 + index * 2])
            return Int16(bitPattern: low | high << 8)
        }
        XCTAssertEqual(Double(sample(0)), 3276, accuracy: 1)
        XCTAssertEqual(Double(sample(8_000)), 6553, accuracy: 1)
        XCTAssertEqual(Double(sample(12_000)), 9830, accuracy: 1)
        f.engine.stop()
        XCTAssertEqual(f.engine.state, .processing)
        f.engine.stop(); f.engine.pause(); f.engine.resume()
        XCTAssertEqual(f.recorders.count, 3)
        await first.open()
        try await waitUntil { f.results.count == 1 }
        XCTAssertEqual(f.cleanup.inputs, ["Phase 1. Phase 2. Phase 3."])
        XCTAssertEqual(f.results[0].entry?.rawText, "Phase 1. Phase 2. Phase 3.")
        XCTAssertEqual(f.results[0].entry?.durationSec, 1.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(f.wavURL).path))
        XCTAssertEqual(f.engine.state, .idle)
    }

    @MainActor
    func testOrderedRawPreviewSurvivesPauseButNeverCreatesCleanupBeforeStop() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        f.config.ui.liveTranscriptPreview = true; f.engine.configure(f.config)
        let first = PauseGate(); f.transcriber.firstGate = first
        try await f.start()
        f.feed(0.1, count: 800); f.segmenters[0].flush()
        f.feed(0.2, count: 800); f.segmenters[0].flush()
        try await waitUntil { f.transcriber.completed == 1 }
        XCTAssertEqual(f.engine.transcriptPreview?.text ?? "", "")
        f.engine.pause(); await first.open()
        try await waitUntil { f.engine.transcriptPreview?.text == "Phase 1. Phase 2." }
        XCTAssertEqual(f.engine.state, .paused)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        f.engine.resume(); try await waitUntil { f.engine.state == .recording }
        XCTAssertEqual(f.engine.transcriptPreview?.text, "Phase 1. Phase 2.")
        f.feed(0.3, count: 800); f.segmenters[1].flush()
        try await waitUntil { f.engine.transcriptPreview?.text == "Phase 1. Phase 2. Phase 3." }
        f.engine.stop()
        XCTAssertNil(f.engine.transcriptPreview)
        try await waitUntil { f.results.count == 1 }
        XCTAssertEqual(f.cleanup.inputs, ["Phase 1. Phase 2. Phase 3."])
        XCTAssertEqual(f.engine.phaseTimings.transcriptionCount, 3)
        XCTAssertEqual(f.cleanup.warmups, 1)
        XCTAssertEqual(f.server.stops, 0)
    }

    @MainActor
    func testSuppressedAndCancelledPreviewCannotReturnFromLateSegment() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        f.config.ui.liveTranscriptPreview = true; f.engine.configure(f.config)
        try await f.start()
        f.feed(0.2, count: 800); f.segmenters[0].flush()
        try await waitUntil { f.engine.transcriptPreview?.text == "Phase 2." }
        f.engine.suppressTranscriptPreview()
        XCTAssertFalse(f.engine.isTranscriptPreviewEnabled)
        f.feed(0.3, count: 800); f.segmenters[0].flush()
        try await waitUntil { f.transcriber.completed == 2 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(f.engine.transcriptPreview)
        f.engine.stop(); try await waitUntil { f.results.count == 1 }
        XCTAssertEqual(f.cleanup.inputs, ["Phase 2. Phase 3."])
        let old = PauseGate(); f.transcriber.firstGate = old
        try await f.start()
        f.feed(0.1, count: 800); f.segmenters.last!.flush()
        f.engine.cancel()
        try await f.start()
        f.feed(0.4, count: 800); f.segmenters.last!.flush()
        try await waitUntil { f.engine.transcriptPreview?.text == "Phase 4." }
        await old.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.engine.transcriptPreview?.text, "Phase 4.")
        f.engine.cancel(); XCTAssertNil(f.engine.transcriptPreview)
    }

    @MainActor
    func testLongSpeechWaitsForExistingVadBoundaryWithoutExtraRequests() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        f.realVAD = true; f.config.ui.liveTranscriptPreview = true
        f.config.vad.minSpeechSec = 0.06; f.config.vad.maxSegmentSec = 2
        f.engine.configure(f.config)
        try await f.start()
        f.feed(0.2, count: 16_000)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.transcriber.completed, 0)
        XCTAssertNil(f.engine.transcriptPreview)
        f.feed(0.2, count: 20_000)
        try await waitUntil { f.engine.transcriptPreview?.text.isEmpty == false }
        XCTAssertEqual(f.transcriber.completed, 1)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        f.engine.cancel(); XCTAssertNil(f.engine.transcriptPreview)
    }

    @MainActor
    func testPreviewOptionRemainsFrozenUntilNextRequest() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        try await f.start()
        f.config.ui.liveTranscriptPreview = true; f.engine.configure(f.config)
        f.feed(0.2, count: 800); f.segmenters[0].flush()
        try await waitUntil { f.transcriber.completed == 1 }
        XCTAssertNil(f.engine.transcriptPreview)
        f.engine.stop(); try await waitUntil { f.results.count == 1 }
        try await f.start()
        f.feed(0.3, count: 800); f.segmenters.last!.flush()
        try await waitUntil { f.engine.transcriptPreview?.text == "Phase 3." }
    }

    @MainActor
    func testTestSessionUsesExistingEngineAndFrozenProfileWithoutAutomaticDelivery() async throws {
        let f = try PauseFixture(privateText: true)
        defer { f.dispose() }
        let session = TestDictationSession(engine: f.engine)
        defer { session.close() }
        bind(session, to: f)
        session.start(configuration: f.config, currentConfiguration: f.config,
                      nextRequestConfiguration: f.config, inputAvailable: true, allowed: true)
        try await waitUntil { session.state == .recording }
        var changed = f.config; changed.history.storeText = true; changed.whisper.language = "en"
        f.engine.configure(changed)
        f.feed(0.1, count: 1_600); session.stop()
        try await waitUntil { session.state == .completed }
        XCTAssertEqual(session.configuration?.history.storeText, false)
        XCTAssertEqual(session.result?.entry?.storesText, false)
        XCTAssertTrue(try f.history.list().isEmpty)
        XCTAssertEqual(f.cleanup.inputs, ["Phase 1."])
        XCTAssertEqual(session.timings.transcriptionCount, 1)
        XCTAssertEqual(session.audioDuration, 0.1)
        XCTAssertEqual(f.server.stops, 0)
        let lastTimings = session.timings
        XCTAssertTrue(session.releaseForRegularStart())
        f.engine.start()
        try await waitUntil { f.engine.state == .recording }
        XCTAssertEqual(f.engine.sessionConfiguration.whisper.language, "en")
        XCTAssertTrue(f.engine.sessionConfiguration.history.storeText)
        XCTAssertEqual(session.timings, lastTimings)
        XCTAssertEqual(session.result?.text, "Phase 1.")
    }

    @MainActor
    func testTestDeadlineRestartsAndClosingCannotCancelRegularDictation() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let clock = PauseClock()
        let session = TestDictationSession(engine: f.engine, maximumRecordingDuration: 1, clock: { clock.now })
        defer { session.close() }
        bind(session, to: f)
        func start() { session.start(configuration: f.config, currentConfiguration: f.config,
                                     nextRequestConfiguration: f.config, inputAvailable: true, allowed: true) }
        start(); try await waitUntil { session.state == .recording }
        f.feed(0.1, count: 1_600); clock.advance(1.2); session.pulse()
        try await waitUntil { session.state == .completed }
        start(); try await waitUntil { session.state == .recording }
        clock.advance(0.2); session.pulse()
        XCTAssertEqual(session.state, .recording)
        f.feed(0.2, count: 1_600); session.stop()
        try await waitUntil { session.state == .completed }
        XCTAssertEqual(f.cleanup.inputs, ["Phase 1.", "Phase 2."])
        session.releaseForRegularStart(); f.engine.start()
        try await waitUntil { f.engine.state == .recording }
        session.close()
        XCTAssertEqual(f.engine.state, .recording)
    }

    @MainActor
    func testTestPreflightNeverStartsAudioForChangedBusyOrMissingInput() throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let session = TestDictationSession(engine: f.engine)
        var changed = f.config; changed.whisper.language = "en"
        for (current, input, allowed) in [(changed, true, true), (f.config, false, true), (f.config, true, false)] {
            session.start(configuration: f.config, currentConfiguration: current,
                          nextRequestConfiguration: f.config, inputAvailable: input, allowed: allowed)
            if case .failed = session.state {} else { XCTFail("Teststart wurde nicht abgewiesen") }
            XCTAssertFalse(session.isActive)
            XCTAssertTrue(f.recorders.isEmpty)
            XCTAssertEqual(f.engine.state, .idle)
        }
    }

    @MainActor
    func testTestCancellationInterruptsPreparationAwaitAndCannotOpenLateRecorder() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let probe = PauseCancellationProbe()
        f.beforePermission = {
            probe.setEntered()
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { probe.setCancelled() }
        }
        let session = TestDictationSession(engine: f.engine)
        bind(session, to: f)
        session.start(configuration: f.config, currentConfiguration: f.config,
                      nextRequestConfiguration: f.config, inputAvailable: true, allowed: true)
        try await waitUntil { probe.entered }
        session.cancel()
        try await waitUntil { probe.cancelled }
        XCTAssertEqual(session.state, .cancelled)
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(f.recorders.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
    }

    @MainActor
    func testTestKeepsOwnershipForErrorAfterValidResultAndClearsOnClose() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let session = TestDictationSession(engine: f.engine)
        bind(session, to: f)
        session.start(configuration: f.config, currentConfiguration: f.config,
                      nextRequestConfiguration: f.config, inputAvailable: true, allowed: true)
        try await waitUntil { session.state == .recording }
        f.feed(0.1, count: 1_600); session.stop()
        try await waitUntil { session.state == .completed }
        session.receiveState(.error("Synthetischer Dateifehler"))
        XCTAssertEqual(session.state, .failed("Synthetischer Dateifehler"))
        XCTAssertEqual(session.result?.text, "Phase 1.")
        XCTAssertTrue(session.owns(f.engine))
        session.close()
        XCTAssertNil(session.result)
        XCTAssertFalse(session.owns(f.engine))
    }

    @MainActor
    func testPhaseTimingsCountOverlappingTranscriptionsWithoutAddingWallTime() async throws {
        let clock = PauseClock()
        let f = try PauseFixture(clock: { clock.now })
        defer { f.dispose() }
        f.beforePermission = { clock.advance(1) }
        f.server.beforeEnsure = { clock.advance(2) }
        f.engine.onBeforeRecordingStart = { clock.advance(3) }
        let first = PauseGate(); f.transcriber.firstGate = first
        let entered = PauseCancellationProbe()
        f.transcriber.onBegin = { number in
            clock.advance(number == 1 ? 4 : 2)
            if number == 1 { entered.setEntered() }
        }
        f.cleanup.onClean = { clock.advance(5) }
        try await f.start()
        f.feed(0.1, count: 1_600); f.engine.pause()
        try await waitUntil { entered.entered }
        f.engine.resume(); try await waitUntil { f.engine.state == .recording }
        // Fortsetzungsvorbereitung gehört nicht zur ursprünglichen Startphase.
        let secondStart = clock.now
        f.feed(0.2, count: 1_600); f.engine.pause()
        try await waitUntil { f.transcriber.completed == 1 }
        f.engine.stop(); await first.open()
        try await waitUntil { f.results.count == 1 }
        let timings = f.engine.phaseTimings
        XCTAssertEqual(timings.preparationSec, 6)
        XCTAssertEqual(timings.recordingSec, 0.2)
        XCTAssertEqual(timings.transcriptionCount, 2)
        XCTAssertEqual(timings.transcriptionSec, secondStart - 6 + 4)
        XCTAssertEqual(timings.cleanupSec, 5)
        XCTAssertEqual(f.results[0].entry?.cleanupSec, timings.cleanupSec)
    }

    @MainActor
    func testLateCancelledTranscriptionCannotChangeNewTimingStore() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        let old = PauseGate(); f.transcriber.firstGate = old
        let entered = PauseCancellationProbe()
        f.transcriber.onBegin = { number in if number == 1 { entered.setEntered() } }
        try await f.start(); f.feed(0.1, count: 1_600); f.engine.pause()
        try await waitUntil { entered.entered }
        f.engine.cancel(); try await f.start()
        f.feed(0.2, count: 1_600); f.engine.pause()
        try await waitUntil { f.transcriber.completed == 1 }
        await old.open()
        try await waitUntil { f.transcriber.completed == 2 }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(f.engine.phaseTimings.transcriptionCount, 1)
        f.engine.stop(); try await waitUntil { f.results.count == 1 }
        XCTAssertEqual(f.results[0].entry?.rawText, "Phase 2.")
        XCTAssertEqual(f.engine.phaseTimings.transcriptionCount, 1)
    }

    @MainActor
    func testPhaseReportExcludesTextProfilePathsAndErrorDetails() async throws {
        let f = try PauseFixture(privateText: true)
        defer { f.dispose() }
        f.cleanup.usedFallback = true
        var raw = f.config
        let profile = Config.Profile(name: "synthetic-secret")
        raw.profiles = [profile]; raw.selectedProfileID = profile.id
        let reviewed = raw.resolvedForRequest()
        let session = TestDictationSession(engine: f.engine)
        defer { session.close() }
        bind(session, to: f)
        session.start(configuration: reviewed, currentConfiguration: reviewed,
                      nextRequestConfiguration: raw, inputAvailable: true, allowed: true)
        try await waitUntil { session.state == .recording }
        f.feed(0.1, count: 1_600); session.stop()
        try await waitUntil { session.state == .completed }
        session.receiveState(.error("synthetic-secret /private/example http://192.0.2.1"))
        let report = session.exportReport(version: "synthetic-secret")
        for forbidden in ["synthetic-secret", "Phase 1.", "/private/", "192.0.2.1"] { XCTAssertFalse(report.contains(forbidden)) }
        XCTAssertTrue(report.contains("test.state=failed"))
        XCTAssertTrue(report.contains("test.source=raw_fallback"))
        XCTAssertTrue(report.contains("test.transcription_count=1"))
        XCTAssertTrue(try f.history.list().isEmpty)
    }

    @MainActor
    private func bind(_ session: TestDictationSession, to f: PauseFixture) {
        f.engine.onStateChange = { [weak session] in session?.receiveState($0) }
        f.engine.onResult = { [weak f, weak session] in f?.results.append($0); session?.receiveResult($0) }
    }

    @MainActor
    func testPrivateResultRetainsTransientRawFallbackWithoutPersistingIt() async throws {
        let f = try PauseFixture(privateText: true)
        defer { f.dispose() }
        f.cleanup.usedFallback = true
        try await f.start()
        f.feed(0.1, count: 1_600)
        f.engine.stop()
        try await waitUntil { f.results.count == 1 }
        let result = f.results[0]
        XCTAssertEqual(result.entry?.cleanupFellBack, true)
        XCTAssertEqual(result.entry?.cleanupFallbackReason, "Synthetischer Rückfall")
        XCTAssertEqual(result.entry?.rawText, "Phase 1.")
        XCTAssertEqual(result.entry?.storesText, false)
        let currentPreview = TransientResultStore.Result(text: result.text, rawFallback: result.entry?.cleanupFellBack == true)
        XCTAssertEqual(currentPreview?.rawFallback, true)
        XCTAssertTrue(try f.history.list().isEmpty)
    }

    @MainActor
    func testPauseInsideRecordingCallbackRejectsLateStartFailure() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        f.engine.onStateChange = { state in
            guard state == .recording else { return }
            f.feed(0.1, count: 1_600)
            let lateFailure = f.recorders.last!.onFailure
            f.engine.pause()
            lateFailure?(PauseError.device)
        }
        f.engine.start()
        try await waitUntil { f.engine.state != .starting }
        XCTAssertEqual(f.engine.state, .paused)
        f.engine.stop()
        try await waitUntil { !f.results.isEmpty || { if case .error = f.engine.state { return true }; return false }() }
        XCTAssertEqual(f.results.count, 1)
        XCTAssertEqual(f.cleanup.inputs, ["Phase 1."])
    }

    @MainActor
    func testResumeFailuresRetainPreviousAudioAndRespectOriginalPrivatePolicy() async throws {
        for boundary in ["permission", "server", "recorder"] {
            for privateText in [false, true] {
                let f = try PauseFixture(privateText: privateText)
                defer { f.dispose() }
                try await f.start()
                f.feed(0.1, count: 4_000)
                f.engine.pause()
                try await waitUntil { f.transcriber.completed == 1 }
                var config = f.config
                config.history.storeText = privateText
                f.engine.configure(config)
                if boundary == "permission" { f.permission = false }
                if boundary == "server" { f.server.fail = true }
                if boundary == "recorder" { f.nextRecorderFailure = true }
                f.engine.resume()
                try await waitUntil { if case .error = f.engine.state { return true }; return false }
                try await waitUntil { (try? f.history.list().count) == 1 }
                let entry = try XCTUnwrap(f.history.list().first)
                XCTAssertEqual(entry.status, "failed")
                XCTAssertEqual(entry.rawText, privateText ? "" : "Phase 1.")
                if privateText { XCTAssertNil(entry.cleanupFellBack); XCTAssertNil(entry.resultMetadata) }
                else { XCTAssertEqual(entry.resultOrigin, .rawFallback) }
                XCTAssertEqual(entry.durationSec, 0.25)
                XCTAssertNotNil(entry.audioFileName)
                XCTAssertEqual(try Data(contentsOf: XCTUnwrap(f.wavURL)).count, 44 + 4_000 * 2)
                XCTAssertTrue(f.results.isEmpty)
                XCTAssertTrue(f.cleanup.inputs.isEmpty)
                await f.engine.shutdown().value
                XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(f.wavURL).path))
            }
        }
    }

    @MainActor
    func testStopDuringEveryResumeAwaitCannotReopenMicrophone() async throws {
        for boundary in ["permission", "server", "sound"] {
            let f = try PauseFixture()
            defer { f.dispose() }
            try await f.start()
            f.feed(0.1, count: 1_600); f.engine.pause()
            let gate = PauseGate()
            var entered = false
            if boundary == "permission" { f.beforePermission = { entered = true; await gate.wait() } }
            if boundary == "server" { f.server.beforeEnsure = { entered = true; await gate.wait() } }
            if boundary == "sound" { f.engine.onBeforeRecordingStart = { entered = true; await gate.wait() } }
            f.engine.resume()
            try await waitUntil { entered }
            f.engine.stop()
            await gate.open()
            try await waitUntil { f.results.count == 1 }
            XCTAssertEqual(f.recorders.count, 1)
            XCTAssertEqual(f.cleanup.inputs, ["Phase 1."])
            XCTAssertEqual(f.results[0].entry?.durationSec, 0.1)
            XCTAssertEqual(f.recorders[0].stops, 1)
        }
    }

    @MainActor
    func testPhysicalReleaseDuringResumeHardwareStartKeepsOnlyPreviousPhase() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        var held = true
        f.engine.start(onlyWhile: { held })
        try await waitUntil { f.engine.state == .recording }
        f.feed(0.1, count: 1_600); f.engine.pause()
        f.nextRecorderStart = { recorder in
            held = false
            recorder.onSamples?(Array(repeating: 0.9, count: 16_000))
        }
        f.engine.resume()
        try await waitUntil { f.results.count == 1 }
        XCTAssertEqual(f.cleanup.inputs, ["Phase 1."])
        XCTAssertEqual(f.results[0].entry?.durationSec, 0.1)
        XCTAssertEqual(f.recorders.count, 2)
        XCTAssertEqual(f.recorders[1].stops, 1)
        XCTAssertTrue(f.segmenters[1].samples.isEmpty)
    }

    @MainActor
    func testCancelFromPauseDiscardsAudioAndLateCallbacks() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        try await f.start()
        f.feed(0.1, count: 1_600)
        let samples = try XCTUnwrap(f.recorders[0].onSamples)
        f.engine.pause(); f.engine.cancel()
        samples([0.9])
        await Task.yield()
        XCTAssertEqual(f.engine.state, .idle)
        XCTAssertFalse(f.engine.hasInFlightRequests)
        XCTAssertTrue(f.results.isEmpty)
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(f.wavURL).path))
    }

    @MainActor
    func testWriterFailureFromPauseKeepsRecognizedTextWithoutFalseAudioRetry() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        try await f.start()
        f.feed(0.1, count: 1_600); f.engine.pause()
        try await waitUntil { f.transcriber.completed == 1 }
        f.writer?.failFinish = true
        f.engine.stop()
        try await waitUntil { (try? f.history.list().count) == 1 }
        let entry = try XCTUnwrap(f.history.list().first)
        XCTAssertEqual(entry.rawText, "Phase 1.")
        XCTAssertEqual(entry.status, "failed")
        XCTAssertFalse(entry.canRetry)
        XCTAssertTrue(entry.errorMessage?.contains(try XCTUnwrap(f.wavURL).path) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(f.wavURL).path))
        XCTAssertTrue(f.cleanup.inputs.isEmpty)
    }

    @MainActor
    func testAutoStopCountsOnlyActiveSilenceAndResetsAtResume() async throws {
        let f = try PauseFixture()
        defer { f.dispose() }
        f.realVAD = true
        f.config.vad.autoStopAfterSilenceSec = 0.3
        f.config.vad.minSpeechSec = 0.06
        f.engine.configure(f.config)
        try await f.start()
        f.feed(0.2, count: 1_920)
        f.feed(0, count: 2_400)
        f.engine.pause()
        f.engine.resume()
        try await waitUntil { f.engine.state == .recording }
        f.feed(0, count: 2_400)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(f.engine.state, .recording, "Die Stille der alten Phase darf nicht mitzählen")
        f.feed(0, count: 2_880)
        try await waitUntil { f.results.count == 1 }
        XCTAssertEqual(f.cleanup.inputs.count, 1)
        XCTAssertEqual(f.results[0].entry?.durationSec, 9_600.0 / 16_000)
    }

    func testAudioBoundaryWaitsForInFlightCallbackAndRejectsOldAndPendingPhases() throws {
        let session = RecordingAudioSession()
        let phase = session.beginPhase(acceptingSamples: true)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            session.consume([0.1], in: phase) { entered.signal(); release.wait() }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async { session.closePhase(); closed.signal() }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.02), .timedOut)
        release.signal()
        XCTAssertEqual(closed.wait(timeout: .now() + 1), .success)
        session.consume([0.9], in: phase) { XCTFail("Alte Phase verarbeitet") }
        let pending = session.beginPhase(acceptingSamples: false)
        session.consume([0.9], in: pending) { XCTFail("Unbestätigte Fortsetzung verarbeitet") }
        session.acceptSamples(in: pending)
        session.consume([0.2], in: pending) {}
        XCTAssertEqual(session.duration, 2.0 / 16_000)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Bedingung nach 2000 Prüfungen nicht erreicht")
    throw PauseError.timeout
}

private enum PauseError: Error { case device, timeout }
private actor PauseGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor
private final class PauseFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let history: HistoryStore
    let transcriber = PauseTranscriber(), server = PauseServer(), cleanup = PauseCleanup()
    var config = Config()
    var engine: DictationEngine!
    var recorders: [PauseRecorder] = []
    var segmenters: [PauseSegmenter] = []
    var wavURL: URL?
    var writer: PauseWriter?
    var realVAD = false
    var permission = true
    var beforePermission: (() async -> Void)?
    var beforeSegmenter: (() async -> Void)?
    var segmenterConfigurations: [Config.Vad] = []
    var nextRecorderFailure = false
    var nextRecorderStart: ((PauseRecorder) -> Void)?
    var results: [DictationResult] = []

    init(privateText: Bool = false, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        history = HistoryStore(baseDir: directory)
        config.whisper.language = "de"
        config.history.storeText = !privateText
        config.cleanup.localOnly = true
        engine = DictationEngine(config: config, history: history, dependencies: .init(
            transcriber: transcriber, server: server, cleanup: cleanup,
            makeRecorder: { [weak self] _ in
                let f = self!, recorder = PauseRecorder()
                recorder.failStart = f.nextRecorderFailure
                let hook = f.nextRecorderStart
                recorder.onStart = { hook?(recorder) }
                f.recorders.append(recorder)
                return recorder
            },
            makeSegmenter: { [weak self] config in
                await self?.beforeSegmenter?()
                self?.segmenterConfigurations.append(config)
                if self!.realVAD { return VadSegmenter(config: config) }
                let segmenter = PauseSegmenter()
                self!.segmenters.append(segmenter)
                return segmenter
            },
            makeWavWriter: { [weak self] url in
                self!.wavURL = url
                let writer = try PauseWriter(url: url)
                self!.writer = writer
                return writer
            },
            makeTranscriber: { [weak self] _ in self!.transcriber },
            monotonicTime: clock,
            requestMicrophoneAccess: { [weak self] in
                await self?.beforePermission?()
                return self?.permission == true
            }
        ))
        engine.onResult = { [weak self] in self?.results.append($0) }
    }
    func start() async throws { engine.start(); try await waitUntil { engine.state == .recording } }
    func feed(_ sample: Float, count: Int) { recorders.last!.onSamples?(Array(repeating: sample, count: count)) }
    func dispose() { engine.cancel(); try? FileManager.default.removeItem(at: directory) }
}

private final class PauseRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    var onStart: (() -> Void)?
    var failStart = false
    var stops = 0
    func start() throws { onStart?(); if failStart { throw PauseError.device } }
    func stop() { stops += 1 }
}
private final class PauseSegmenter: DictationSegmenter {
    var onSegment: ((VadSegmenter.Segment) -> Void)?, onAutoStop: (() -> Void)?
    var currentLevelDb: Double { -20 }
    var samples: [Float] = []
    func process(_ samples: [Float]) { self.samples += samples }
    func flush() {
        guard !samples.isEmpty else { return }
        onSegment?(.init(samples: samples, hadSpeech: true, reason: .flush))
        samples = []
    }
}
private final class PauseServer: DictationServer {
    var stops = 0, fail = false
    var beforeEnsure: (() async -> Void)?
    func ensureRunning(reachability: any DictationTranscriber) async throws {
        await beforeEnsure?()
        if fail { throw PauseError.device }
    }
    func stop() { stops += 1 }
}
private final class PauseCleanup: DictationCleanup {
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    var warmups = 0, usedFallback = false
    var inputs: [String] = []
    var onClean: (() -> Void)?
    func warmUp() { warmups += 1 }
    func clean(_ rawText: String) async -> CleanupService.Result {
        onClean?()
        inputs.append(rawText)
        return .init(text: rawText, usedFallback: usedFallback, fallbackReason: usedFallback ? "Synthetischer Rückfall" : nil, endpoint: nil)
    }
}
private final class PauseTranscriber: DictationTranscriber {
    private let lock = NSLock()
    private var completedCount = 0
    var completed: Int { lock.withLock { completedCount } }
    var firstGate: PauseGate?
    var onBegin: ((Int) async -> Void)?
    func transcribe(samples: [Float]) async throws -> String {
        let number = Int((Double(samples.first ?? 0) * 10).rounded())
        await onBegin?(number)
        if number == 1 { await firstGate?.wait() }
        lock.withLock { completedCount += 1 }
        return "Phase \(number)."
    }
    func transcribe(wavFile: URL) async throws -> String { "Datei." }
    func isReachable() async -> Bool { true }
}

private final class PauseWriter: DictationWavWriter {
    let writer: WavFileWriter
    var failFinish = false
    var url: URL { writer.url }
    init(url: URL) throws { writer = try WavFileWriter(url: url) }
    func append(_ samples: [Float]) throws { try writer.append(samples) }
    func finish() throws { if failFinish { throw PauseError.device }; try writer.finish() }
}

private final class PauseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}
private final class PauseCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false, didCancel = false
    var entered: Bool { lock.withLock { didEnter } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func setEntered() { lock.withLock { didEnter = true } }
    func setCancelled() { lock.withLock { didCancel = true } }
}
