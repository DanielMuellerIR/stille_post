import XCTest
import CryptoKit
@testable import StillePostCore

final class SileroVadTests: XCTestCase {
    private final class Detector: SpeechActivityDetector {
        let frameSize = 4096
        var calls = 0
        let failingCall: Int?
        init(failingCall: Int? = nil) { self.failingCall = failingCall }
        func isSpeech(_ samples: [Float]) throws -> Bool {
            calls += 1
            if calls == failingCall { throw SileroModel.Failure.unavailable }
            return samples.contains { $0 > 0.01 }
        }
    }

    func testOldInvalidAndRoundTrippedSelection() throws {
        for json in ["{}", "{\"detector\":\"future\"}", "{\"detector\":true}", "{\"detector\":null}"] {
            let config = try JSONDecoder().decode(Config.Vad.self, from: Data(json.utf8))
            XCTAssertEqual(config.detector, .rms)
        }
        var config = Config.Vad()
        config.detector = .silero
        XCTAssertEqual(try JSONDecoder().decode(Config.Vad.self, from: JSONEncoder().encode(config)), config)
    }

    func testFailedWindowIsReplayedInRmsFramesWithoutLossOrFalseClick() {
        var config = Config.Vad()
        config.paddingSec = 0
        config.minSegmentSec = 10
        config.maxSegmentSec = 30
        let broken = Detector(failingCall: 1)
        let candidate = VadSegmenter(config: config, detector: broken)
        let baseline = VadSegmenter(config: config)
        var result: [VadSegmenter.Segment] = []
        var reference: [VadSegmenter.Segment] = []
        var fallbacks = 0
        candidate.onSegment = { result.append($0) }
        baseline.onSegment = { reference.append($0) }
        candidate.onFallback = { _ in fallbacks += 1 }
        var click = [Float](repeating: 0, count: 4096)
        for i in 1000..<1480 { click[i] = 0.2 }
        let speech = [Float](repeating: 0.15, count: 9600)
        for chunk in [click, speech, [Float](repeating: 0, count: 5000)] {
            candidate.process(chunk); baseline.process(chunk)
        }
        candidate.flush(); baseline.flush()
        XCTAssertEqual(broken.calls, 1)
        XCTAssertEqual(fallbacks, 1)
        XCTAssertNotNil(candidate.fallbackReason)
        XCTAssertEqual(result.map(\.samples), reference.map(\.samples))
        XCTAssertEqual(result.map(\.hadSpeech), reference.map(\.hadSpeech))
        let clickOnly = VadSegmenter(config: config, detector: Detector(failingCall: 1))
        clickOnly.onSegment = { XCTAssertFalse($0.hadSpeech) }
        clickOnly.process(click); clickOnly.flush()
    }

    func testPartialWindowFlushPreservesOriginalAudioAndNoPaddingSamples() {
        var config = Config.Vad()
        config.paddingSec = 0
        let segmenter = VadSegmenter(config: config, detector: Detector())
        let audio = (0..<3000).map { Float($0 + 1) / 4000 }
        var segments: [VadSegmenter.Segment] = []
        segmenter.onSegment = { segments.append($0) }
        segmenter.process(audio)
        XCTAssertTrue(segments.isEmpty)
        segmenter.flush(); segmenter.flush()
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].hadSpeech)
        XCTAssertEqual(segments[0].samples, audio)
    }

    func testLevelAndAutoStopIndependentOfModelWindowAndBoundedSilence() {
        var config = Config.Vad()
        config.autoStopAfterSilenceSec = 0.6
        config.maxSegmentSec = 1
        config.minSegmentSec = 0.5
        let segmenter = VadSegmenter(config: config, detector: Detector())
        var stops = 0
        var discarded = 0
        segmenter.onAutoStop = { stops += 1 }
        segmenter.onSegment = { segment in
            XCTAssertFalse(segment.hadSpeech)
            XCTAssertLessThanOrEqual(segment.samples.count, 32000)
            discarded += 1
        }
        segmenter.process([Float](repeating: 0.001, count: 480))
        XCTAssertEqual(segmenter.currentLevelDb, -60, accuracy: 0.01)
        segmenter.process([Float](repeating: 0, count: 160000))
        segmenter.flush()
        XCTAssertEqual(stops, 1)
        XCTAssertGreaterThan(discarded, 5)
    }

    func testMissingAndDamagedModelFallBackWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = Config.Vad()
        config.detector = .silero
        let absent = await VadSegmenter.prepared(config: config, modelDirectory: root)
        XCTAssertEqual(absent.fallbackReason, SileroModel.Failure.missing.localizedDescription)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("model.mil"))
        let damaged = await VadSegmenter.prepared(config: config, modelDirectory: root)
        XCTAssertEqual(damaged.fallbackReason, SileroModel.Failure.integrity.localizedDescription)
    }

    func testIntegrityRejectsSameSizeMutationAndOversize() throws {
        let data = Data([1,2,3,4])
        let spec = SileroModel.FileSpec(name: "test", bytes: 4,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertNoThrow(try SileroModel.verify(data, spec: spec))
        XCTAssertThrowsError(try SileroModel.verify(Data([1,2,3,5]), spec: spec))
        XCTAssertThrowsError(try SileroModel.verify(data + Data([0]), spec: spec))
    }

    func testRealModelInstallFailureCancellationAndRepairPreserveExistingData() async throws {
        guard let source = ProcessInfo.processInfo.environment["STILLEPOST_SILERO_TEST_MODEL"] else {
            throw XCTSkip("Festes Silero-Testmodell nicht bereitgestellt")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent(SileroModel.name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("preserved.txt")
        try Data("retain".utf8).write(to: sentinel)
        do {
            try await SileroModel.install(at: target) { _ in throw SileroModel.Failure.download }
            XCTFail("Downloadfehler muss propagieren")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        do {
            try await SileroModel.install(at: target) { _ in throw CancellationError() }
            XCTFail("Abbruch muss propagieren")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        try await SileroModel.install(at: target) { spec in
            try Data(contentsOf: URL(fileURLWithPath: source).appendingPathComponent(spec.name))
        }
        try SileroModel.validate(at: target)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("preserved.txt").path) })
        let detector = try SileroSpeechDetector(directory: target)
        XCTAssertFalse(try detector.isSpeech([Float](repeating: 0, count: 4096)))
        let fresh = try SileroSpeechDetector(directory: target)
        XCTAssertFalse(try fresh.isSpeech([Float](repeating: 0, count: 3000)))
    }
}
