import Foundation
import XCTest
@testable import StillePostCore

final class LinuxAudioRetryTests: XCTestCase {
    func testRetainedAudioWithoutDurationCanRetry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retained-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavFileWriter(url: url)
        try writer.append(Array(repeating: 0.125, count: 1600))
        try writer.finish()
        let work = AudioFileImportWork(source: url, workingURL: url, limits: .shortClip,
            makeWriter: { try WavFileWriter(url: $0) }, beforeChunk: nil)
        try work.prepareRetainedAudio()
        XCTAssertTrue(work.isComplete)
        XCTAssertEqual(work.audioDuration, 0.1, accuracy: 0.0001)
    }
}
