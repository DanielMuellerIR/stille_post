import XCTest
@testable import StillePostCore

/// Tests für die Stille-Erkennung und Segmentierung — das Herzstück der
/// Streaming-Pipeline. Wir füttern synthetische Signale (Sinuston = "Sprache",
/// Nullen = Stille) und prüfen, dass an den richtigen Stellen geschnitten wird.
final class VadSegmenterTests: XCTestCase {

    /// Baut ein Test-VAD mit vorhersagbaren Schwellen.
    private func makeConfig() -> Config.Vad {
        var config = Config.Vad()
        config.silenceThresholdDb = -45
        config.splitAfterSilenceSec = 0.5
        config.minSegmentSec = 1.0
        config.maxSegmentSec = 10
        config.paddingSec = 0.1
        config.autoStopAfterSilenceSec = 0  // in Tests standardmäßig aus
        return config
    }

    /// Sekunden -> Anzahl Samples bei 16 kHz.
    private func samples(seconds: Double) -> Int { Int(seconds * Double(WavCodec.sampleRate)) }

    /// "Sprache": Sinuston mit deutlicher Lautstärke (weit über der Schwelle).
    private func tone(seconds: Double) -> [Float] {
        (0..<samples(seconds: seconds)).map { index in
            0.5 * sin(2 * .pi * 440 * Float(index) / Float(WavCodec.sampleRate))
        }
    }

    /// Stille: reine Nullen (unter jeder Schwelle).
    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: samples(seconds: seconds))
    }

    func testSplitsAtPause() {
        let segmenter = VadSegmenter(config: makeConfig())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        // 2 s Sprache, 1 s Pause (> 0,5 s Schwelle) -> Segment 1 wird geschlossen.
        segmenter.process(tone(seconds: 2))
        segmenter.process(silence(seconds: 1))
        // Danach nochmal Sprache; flush() liefert den Rest als letztes Segment.
        segmenter.process(tone(seconds: 1.5))
        segmenter.flush()

        XCTAssertEqual(segments.count, 2, "Erwartet: Schnitt an der Pause + Rest bei flush")
        XCTAssertTrue(segments[0].hadSpeech)
        XCTAssertEqual(segments[0].reason, .pause)
        XCTAssertEqual(segments[1].reason, .flush)
    }

    func testSilenceOnlyIsMarked() {
        let segmenter = VadSegmenter(config: makeConfig())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(silence(seconds: 2))
        segmenter.flush()

        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].hadSpeech, "Reine Stille muss als sprachlos markiert sein (wird verworfen)")
    }

    func testMaxLengthForcesSplit() {
        var config = makeConfig()
        config.maxSegmentSec = 3
        let segmenter = VadSegmenter(config: config)
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        // 7 s durchgehende Sprache ohne Pause -> muss bei 3 s und 6 s geschnitten werden.
        segmenter.process(tone(seconds: 7))
        segmenter.flush()

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].reason, .maxLength)
        XCTAssertEqual(segments[1].reason, .maxLength)
    }

    func testShortUtteranceNotSplitEarly() {
        let segmenter = VadSegmenter(config: makeConfig())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        // 0,4 s Sprache (unter minSegmentSec) + 0,6 s Pause -> noch KEIN Schnitt.
        segmenter.process(tone(seconds: 0.4))
        segmenter.process(silence(seconds: 0.6))
        XCTAssertEqual(segments.count, 0, "Zu kurze Segmente dürfen nicht an der Pause geschnitten werden")

        segmenter.flush()
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].hadSpeech)
    }

    func testAutoStopFiresAfterLongSilence() {
        var config = makeConfig()
        config.autoStopAfterSilenceSec = 2
        let segmenter = VadSegmenter(config: config)
        var autoStopped = false
        segmenter.onAutoStop = { autoStopped = true }
        segmenter.onSegment = { _ in }

        segmenter.process(tone(seconds: 1))
        segmenter.process(silence(seconds: 1.5))
        XCTAssertFalse(autoStopped, "Noch unter der Abwesenheits-Schwelle")
        segmenter.process(silence(seconds: 1))
        XCTAssertTrue(autoStopped, "2,5 s Stille am Stück > 2 s Schwelle")
    }

    /// Dauer eines Segments in Sekunden.
    private func seconds(_ segment: VadSegmenter.Segment) -> Double {
        Double(segment.samples.count) / Double(WavCodec.sampleRate)
    }

    /// Config, die NIE an der Pause schneidet — nur so sind die Schließgründe
    /// `.flush` und `.maxLength` in einem Test überhaupt erreichbar.
    private func configWithoutPauseSplit() -> Config.Vad {
        var config = makeConfig()
        config.splitAfterSilenceSec = 1000
        return config
    }

    /// Stille am Segmentende muss auch beim Aufnahme-Ende gekürzt werden.
    /// Real reproduziert: "Okay" + 30 s Stille -> Whisper erfindet " Vielen Dank."
    func testTrimsTrailingSilenceOnFlush() {
        let segmenter = VadSegmenter(config: configWithoutPauseSplit())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(tone(seconds: 2))
        segmenter.process(silence(seconds: 3))
        segmenter.flush()

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].reason, .flush)
        // 2 s Sprache + 0,1 s Polster — die restlichen 2,9 s Stille sind weg.
        XCTAssertEqual(seconds(segments[0]), 2.1, accuracy: 0.05,
                       "Stille am Ende muss bei .flush auf paddingSec gekürzt werden")
    }

    /// Dasselbe am 30-s-Hardlimit: Wer eine Aufnahme laufen lässt, ohne zu reden,
    /// füllt das Segment mit Stille — die darf Whisper nicht sehen.
    func testTrimsTrailingSilenceOnMaxLength() {
        var config = configWithoutPauseSplit()
        config.maxSegmentSec = 3
        let segmenter = VadSegmenter(config: config)
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(tone(seconds: 1))
        segmenter.process(silence(seconds: 2))

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].reason, .maxLength)
        XCTAssertEqual(seconds(segments[0]), 1.1, accuracy: 0.05,
                       "Stille am Ende muss bei .maxLength auf paddingSec gekürzt werden")
    }

    /// Auch der Vorlauf zählt: zwischen Aufnahmestart und erstem Wort liegt Stille.
    func testTrimsLeadingSilence() {
        let segmenter = VadSegmenter(config: configWithoutPauseSplit())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(silence(seconds: 3))
        segmenter.process(tone(seconds: 2))
        segmenter.flush()

        XCTAssertEqual(segments.count, 1)
        // 0,1 s Polster + 2 s Sprache — die restlichen 2,9 s Stille sind weg.
        XCTAssertEqual(seconds(segments[0]), 2.1, accuracy: 0.05,
                       "Stille am Anfang muss auf paddingSec gekürzt werden")
    }

    /// Gegenprobe: Durchgehende Sprache darf der Trim nicht anfassen.
    func testDoesNotTrimContinuousSpeech() {
        let segmenter = VadSegmenter(config: configWithoutPauseSplit())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(tone(seconds: 2))
        segmenter.flush()

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(seconds(segments[0]), 2.0, accuracy: 0.05,
                       "Ohne Stille darf nichts gekürzt werden")
    }

    /// Ein kurzer Transient (Tastenklick beim Stoppen der Aufnahme, Türklappen)
    /// darf ein sonst stilles Segment NICHT zu einem Sprach-Segment machen.
    /// Genau das war die Ursache der "Vielen Dank"-Halluzinationen: Das Segment ging
    /// an Whisper, und auf Stille erfindet Whisper Floskeln. Real reproduziert —
    /// 0,25 s Stille + 25 ms Klick liefert " Vielen Dank.".
    func testShortTransientIsNotSpeech() {
        let segmenter = VadSegmenter(config: makeConfig())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(silence(seconds: 2))
        segmenter.process(tone(seconds: 0.03))   // ein einziger 30-ms-Frame
        segmenter.process(silence(seconds: 2))
        segmenter.flush()

        XCTAssertFalse(segments.contains { $0.hadSpeech },
                       "Ein 30-ms-Klick ist keine Sprache — sonst bekommt Whisper reine Stille")
    }

    /// Gegenprobe zur Klick-Schwelle: Das kürzeste echte Wort muss durchkommen.
    /// Gemessen liegen "ja"/"doch" bei rund 0,27 s Sprache, die Schwelle bei 0,15 s.
    func testShortWordStillCountsAsSpeech() {
        let segmenter = VadSegmenter(config: makeConfig())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(silence(seconds: 1))
        segmenter.process(tone(seconds: 0.27))
        segmenter.process(silence(seconds: 1))
        segmenter.flush()

        XCTAssertTrue(segments.contains { $0.hadSpeech },
                      "Ein kurzes Wort wie \"ja\" darf nicht als Klick verworfen werden")
    }

    /// Sprache wird aufsummiert, nicht am Stück gemessen: Auch stockendes Sprechen
    /// mit Mini-Pausen muss als Sprache gelten.
    func testSpeechAccumulatesAcrossGaps() {
        let segmenter = VadSegmenter(config: makeConfig())
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        for _ in 0..<4 {
            segmenter.process(tone(seconds: 0.06))
            segmenter.process(silence(seconds: 0.1))
        }
        segmenter.flush()

        XCTAssertTrue(segments.contains { $0.hadSpeech },
                      "4 x 0,06 s = 0,24 s Sprache liegen über der Schwelle")
    }

    func testLevelReporting() {
        let segmenter = VadSegmenter(config: makeConfig())
        segmenter.onSegment = { _ in }
        segmenter.process(tone(seconds: 0.1))
        XCTAssertGreaterThan(segmenter.currentLevelDb, -20, "Lauter Ton muss hohen Pegel melden")
        segmenter.process(silence(seconds: 0.1))
        XCTAssertLessThan(segmenter.currentLevelDb, -60, "Stille muss sehr niedrigen Pegel melden")
    }

    func testInvalidNegativePaddingCannotCrashSegmentClosure() {
        var config = makeConfig()
        config.paddingSec = -1
        let segmenter = VadSegmenter(config: config)
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }

        segmenter.process(tone(seconds: 1))
        segmenter.flush()

        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].samples.isEmpty)
    }

    func testLevelSnapshotSupportsConcurrentAudioWritesAndUiReads() {
        let segmenter = VadSegmenter(config: makeConfig())
        let group = DispatchGroup()
        let audioQueue = DispatchQueue(label: "stillepost.test.audio")
        let uiQueue = DispatchQueue(label: "stillepost.test.ui")
        let frame = tone(seconds: 0.03)

        group.enter()
        audioQueue.async {
            for _ in 0..<2_000 { segmenter.process(frame) }
            group.leave()
        }
        group.enter()
        uiQueue.async {
            for _ in 0..<20_000 { _ = segmenter.currentLevelDb }
            group.leave()
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThan(segmenter.currentLevelDb, -20)
    }
}
