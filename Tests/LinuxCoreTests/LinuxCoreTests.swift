import XCTest
@testable import StillePostCore
final class LinuxCoreTests: XCTestCase {
    func testOwnedChildWithIgnoredTermIsStillReaped() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec sleep 60"]
        try process.run()
        Thread.sleep(forTimeInterval: 0.05)
        LinuxChildProcess.stop(process)
        XCTAssertFalse(process.isRunning)
    }
    func testAudioBoundary() throws {
        XCTAssertThrowsError(try WhisperEndpoint(serverURL: "http://localhost:8181"))
        XCTAssertThrowsError(try WhisperEndpoint(serverURL: "http://192.0.2.1:8181"))
        XCTAssertNoThrow(try WhisperEndpoint(serverURL: "http://127.0.0.1:8181"))
    }
}
