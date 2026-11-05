import XCTest

@testable import StillePostCore

final class LinuxSileroTests: XCTestCase {
    func testAbsentAndCorruptedModelUseExplicitRMSFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var config = Config.Vad()
        config.detector = .silero
        let missing = await VadSegmenter.prepared(config: config, modelDirectory: folder)
        XCTAssertNotNil(missing.fallbackReason)
        try Data(repeating: 0, count: SileroModel.bytes).write(
            to: folder.appendingPathComponent(SileroModel.name))
        let corrupt = await VadSegmenter.prepared(config: config, modelDirectory: folder)
        XCTAssertNotNil(corrupt.fallbackReason)
        XCTAssertThrowsError(try SileroSpeechDetector(directory: folder))
    }
    func testRealModelKeepsStateLocalToOneRecordingPhase() throws {
        guard let path = ProcessInfo.processInfo.environment["STILLEPOST_SILERO_TEST_MODEL"] else {
            throw XCTSkip("Explizite Modellfixture fehlt")
        }
        let folder = URL(fileURLWithPath: path)
        let first = try SileroSpeechDetector(directory: folder)
        let second = try SileroSpeechDetector(directory: folder)
        let silence = [Float](repeating: 0, count: 4096)
        let initial = try first.probability(silence)
        XCTAssertLessThan(initial, 0.85)
        _ = try first.probability((0..<4096).map { Float(sin(Double($0) * 0.11) * 0.4) })
        XCTAssertEqual(try second.probability(silence), initial, accuracy: 0.000001)
        XCTAssertThrowsError(try first.probability([Float.nan]))
        XCTAssertThrowsError(try first.probability([]))
        XCTAssertThrowsError(try first.probability([Float](repeating: 0, count: 4097)))
    }
}
