import XCTest
@testable import StillePostClientCore

@MainActor final class SessionTests: XCTestCase {
    func testStopThenExplicitSendDeletesOnlyAfterSuccess() async throws {
        let capture = FakeCapture(), files = FakeFiles(), bridge = FakeBridge()
        let session = DictationSession(capture: capture, files: files, bridge: bridge)
        session.record(); try await wait { session.state.phase == .recording }
        let before = await bridge.count; XCTAssertEqual(before, 0)
        session.stop(); XCTAssertEqual(session.state.phase, .ready)
        XCTAssertNotNil(files.recording)
        session.send(credentials: credentials)
        try await wait { session.state.phase == .result }
        XCTAssertEqual(session.state.reply?.text, "Ein Test.")
        XCTAssertNil(files.recording); XCTAssertEqual(files.discards, 1)
        let after = await bridge.count; XCTAssertEqual(after, 1)
    }

    func testFailureRetainsRecordingAndExplicitRetryUsesNewSnapshot() async throws {
        let files = FakeFiles(recording: clip), bridge = FakeBridge()
        await bridge.setFailure(.unauthorized)
        let session = DictationSession(capture: FakeCapture(), files: files, bridge: bridge)
        XCTAssertTrue(session.state.recovered)
        session.send(credentials: credentials)
        try await wait { session.state.phase == .failed }
        XCTAssertEqual(session.state.failure, .unauthorized)
        XCTAssertNotNil(files.recording); XCTAssertEqual(files.discards, 0)
        await bridge.setFailure(nil)
        session.send(credentials: BridgeCredentials(configuration: credentials.configuration, token: "second-fixture"))
        try await wait { session.state.phase == .result }
        let tokens = await bridge.tokens
        XCTAssertEqual(tokens, ["fixture-token", "second-fixture"])
    }

    func testCancelDuringUploadIgnoresLateSuccessAndKeepsAudio() async throws {
        let files = FakeFiles(recording: clip), bridge = FakeBridge()
        await bridge.setDelay(100_000_000)
        let session = DictationSession(capture: FakeCapture(), files: files, bridge: bridge)
        session.send(credentials: credentials)
        try await wait { await bridge.count == 1 }
        session.cancel(); XCTAssertEqual(session.state.phase, .ready)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(session.state.reply)
        XCTAssertNotNil(files.recording); XCTAssertEqual(files.discards, 0)
    }

    func testRecordingCancelDiscardsAndInterruptionRetains() async throws {
        let capture = FakeCapture(), files = FakeFiles()
        let session = DictationSession(capture: capture, files: files, bridge: FakeBridge())
        session.record(); try await wait { session.state.phase == .recording }
        session.cancel(); XCTAssertEqual(session.state.phase, .idle); XCTAssertNil(files.recording)
        session.record(); try await wait { session.state.phase == .recording }
        session.interrupt(); XCTAssertEqual(session.state.failure, .interrupted)
        XCTAssertNotNil(files.recording); XCTAssertEqual(capture.stops, 2)
    }

    func testPermissionDeniedAndAutomaticDurationStop() async throws {
        let capture = FakeCapture(), files = FakeFiles()
        capture.failure = .microphoneDenied
        let session = DictationSession(capture: capture, files: files, bridge: FakeBridge())
        session.record(); try await wait { session.state.phase == .failed }
        XCTAssertEqual(session.state.failure, .microphoneDenied)
        session.discard(); capture.failure = nil
        session.record(); try await wait { session.state.phase == .recording }
        capture.onStopped?(180, nil)
        XCTAssertEqual(session.state.phase, .ready); XCTAssertEqual(session.state.recording?.duration, 180)
    }

    func testDeletionFailureKeepsTextAndDoesNotResendSuccessfulDictation() async throws {
        let files = FakeFiles(recording: clip), bridge = FakeBridge()
        files.failDiscard = true
        let session = DictationSession(capture: FakeCapture(), files: files, bridge: bridge)
        session.send(credentials: credentials)
        try await wait { session.state.phase == .failed }
        XCTAssertNotNil(session.state.reply); XCTAssertNotNil(session.state.recording)
        session.send(credentials: credentials)
        let count = await bridge.count; XCTAssertEqual(count, 1)
        files.failDiscard = false; session.discard(); XCTAssertEqual(session.state.phase, .idle)
    }

    func testFilesSurviveRestartAndDoNotOverwriteExistingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingRecordingFiles(directory: directory)
        let url = try store.prepare(); try Data([1, 2, 3]).write(to: url)
        _ = try store.finish(duration: 3)
        let reopened = PendingRecordingFiles(directory: directory)
        XCTAssertEqual(try reopened.existing()?.duration, 3)
        XCTAssertThrowsError(try reopened.prepare())
        let neighbor = directory.appendingPathComponent("user-original.wav")
        try Data([9]).write(to: neighbor); try reopened.discard()
        XCTAssertNil(try reopened.existing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
    }

    private var clip: Recording { Recording(url: URL(fileURLWithPath: "/fixture.m4a"), duration: 3, bytes: 100) }
    private var credentials: BridgeCredentials {
        BridgeCredentials(configuration: BridgeConfiguration(address: "http://mac.local", allowInsecureDevelopment: true), token: "fixture-token")
    }
    private func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Erwarteter Zustand fehlt"); throw ClientFailure.unavailable }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor final class FakeCapture: AudioCapture {
    var onProgress: ((TimeInterval) -> Void)?
    var onStopped: ((TimeInterval, ClientFailure?) -> Void)?
    var failure: ClientFailure?
    var stops = 0
    func start(at url: URL, maxDuration: TimeInterval) async throws { if let failure { throw failure } }
    func stop() -> TimeInterval { stops += 1; return 3 }
}

@MainActor final class FakeFiles: RecordingFiles {
    var recording: Recording?
    var discards = 0
    var failDiscard = false
    init(recording: Recording? = nil) { self.recording = recording }
    func existing() throws -> Recording? { recording }
    func prepare() throws -> URL { URL(fileURLWithPath: "/fixture.m4a") }
    func finish(duration: TimeInterval) throws -> Recording {
        let value = Recording(url: URL(fileURLWithPath: "/fixture.m4a"), duration: duration, bytes: 100)
        recording = value; return value
    }
    func discard() throws {
        if failDiscard { throw ClientFailure.storageFailed }
        discards += 1; recording = nil
    }
}

actor FakeBridge: BridgeAccess {
    var count = 0
    var tokens: [String] = []
    private var failure: ClientFailure?
    private var delay: UInt64 = 0
    func setFailure(_ failure: ClientFailure?) { self.failure = failure }
    func setDelay(_ delay: UInt64) { self.delay = delay }
    func health(_ credentials: BridgeCredentials) async throws -> BridgeHealth { throw ClientFailure.unavailable }
    func dictate(_ recording: Recording, credentials: BridgeCredentials, progress: @escaping @Sendable (Double) -> Void) async throws -> DictationReply {
        count += 1; tokens.append(credentials.token)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        return DictationReply(text: "Ein Test.")
    }
}
