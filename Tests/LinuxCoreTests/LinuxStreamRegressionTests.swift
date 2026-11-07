import Foundation
import XCTest
@testable import StillePostCore

final class LinuxStreamRegressionTests: XCTestCase {
    func testFloatSamplesSurviveEveryChunkBoundary() throws {
        let expected: [Float] = [0.25, -0.5, 1, 0]
        let bytes = expected.flatMap { value -> [UInt8] in
            let bits = value.bitPattern
            return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        for size in 1...7 {
            var decoder = LinuxFloatSamples(), output: [Float] = []
            for index in stride(from: 0, to: bytes.count, by: size) {
                output += decoder.append(Data(bytes[index..<min(index + size, bytes.count)]))
            }
            try decoder.finish()
            XCTAssertEqual(output, expected)
        }
        var incomplete = LinuxFloatSamples()
        _ = incomplete.append(Data([1, 2, 3]))
        XCTAssertThrowsError(try incomplete.finish())
    }

    func testInputWaitsForEOFAndDecodesSplitUnicode() throws {
        let pipe = Pipe()
        let expected = String(repeating: "ä", count: 70_000)
        let bytes = Data(expected.utf8)
        let finished = expectation(description: "writer closed")
        DispatchQueue.global().async {
            defer { try? pipe.fileHandleForWriting.close(); finished.fulfill() }
            try? pipe.fileHandleForWriting.write(contentsOf: bytes.prefix(1))
            Thread.sleep(forTimeInterval: 0.02)
            try? pipe.fileHandleForWriting.write(contentsOf: bytes.dropFirst())
        }
        XCTAssertEqual(try LinuxWorker.readStandardInput(from: pipe.fileHandleForReading), expected)
        wait(for: [finished], timeout: 5)
        try pipe.fileHandleForReading.close()
    }

    func testInputRejectsSizeLimitAndInvalidUTF8() throws {
        for bytes in [Data(repeating: 65, count: 11), Data([0xFF])] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: bytes)
            try pipe.fileHandleForWriting.close()
            XCTAssertThrowsError(try LinuxWorker.readStandardInput(from: pipe.fileHandleForReading, maximumBytes: 10))
            try pipe.fileHandleForReading.close()
        }
    }

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
