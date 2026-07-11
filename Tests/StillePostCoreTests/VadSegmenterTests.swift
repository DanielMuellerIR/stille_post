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

    func testLevelReporting() {
        let segmenter = VadSegmenter(config: makeConfig())
        segmenter.onSegment = { _ in }
        segmenter.process(tone(seconds: 0.1))
        XCTAssertGreaterThan(segmenter.currentLevelDb, -20, "Lauter Ton muss hohen Pegel melden")
        segmenter.process(silence(seconds: 0.1))
        XCTAssertLessThan(segmenter.currentLevelDb, -60, "Stille muss sehr niedrigen Pegel melden")
    }
}
