import XCTest
@testable import StillePostCore

final class SelectionCleanupTests: XCTestCase {
    func testReplacementRequiresExactProcessElementRangeTextAndPermission() throws {
        let text = "a🙂é", token = UUID(), range = NSRange(location: 4, length: text.utf16.count)
        func snapshot(process: String = "one", element: UUID? = nil, location: Int = 4,
                      value: String = "a🙂é", writable: Bool = true) throws -> TextSelectionSnapshot {
            try .init(applicationIdentity: process, elementIdentity: element ?? token,
                range: NSRange(location: location, length: value.utf16.count), text: value, supportsReplacement: writable)
        }
        let original = try snapshot()
        XCTAssertEqual(original.range, range)
        XCTAssertTrue(original.permitsReplacement(with: original, foreignApplicationActivated: false))
        XCTAssertFalse(original.permitsReplacement(with: original, foreignApplicationActivated: true))
        for current in [try snapshot(process: "restarted"), try snapshot(element: UUID()),
                        try snapshot(location: 5), try snapshot(value: "b🙂é"), try snapshot(writable: false)] {
            XCTAssertFalse(original.permitsReplacement(with: current, foreignApplicationActivated: false))
        }
        XCTAssertThrowsError(try snapshot(location: NSNotFound))
        XCTAssertThrowsError(try TextSelectionSnapshot(applicationIdentity: "one", elementIdentity: token,
            range: NSRange(location: 4, length: 1), text: text, supportsReplacement: true))
        let angstrom = try snapshot(value: "Å")
        let normalized = try snapshot(value: "Å")
        XCTAssertEqual(angstrom.text, normalized.text)
        XCTAssertFalse(angstrom.permitsReplacement(with: normalized, foreignApplicationActivated: false))
    }

    func testBoundCountsUTF8BytesAndRejectsEmptySelection() throws {
        XCTAssertNoThrow(try TextSelectionSnapshot.validate(String(repeating: "🙂", count: 2048)))
        XCTAssertThrowsError(try TextSelectionSnapshot.validate(String(repeating: "🙂", count: 2049)))
        XCTAssertThrowsError(try TextSelectionSnapshot.validate(" \n\t"))
    }

    func testExecutionSnapshotRejectsBrokenConfigurationInsteadOfReplacingPrivacyPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = ConfigFile(url: root.appendingPathComponent("config.json"))
        var config = Config(); config.cleanup.localOnly = true
        try file.save(config)
        XCTAssertEqual(try file.loadSnapshot(), config)
        try Data("{broken".utf8).write(to: file.url, options: .atomic)
        XCTAssertThrowsError(try file.loadSnapshot())
    }

    @MainActor func testWholeSelectionUsesFrozenAppProfileAndOneCleanup() async throws {
        var config = Config(); config.cleanup.enabled = false
        var profile = Config.Profile(name: "DE lokal"); profile.language = "de"; profile.spokenFormatting = true
        config.profiles = [profile]; config.appProfiles = ["com.example.selection": profile.id]
        let session = SelectionCleanupSession(), gate = SelectionTestGate()
        let raw = "128, nicht 256. Format neuer Absatz Version 1.2."
        var calls = 0
        try session.start(text: raw, configuration: config, appBundleID: "com.example.selection") { cleanup, input in
            calls += 1; XCTAssertTrue(cleanup.spokenFormatting); XCTAssertEqual(input, raw)
            await gate.wait(); return await CleanupService(config: cleanup).clean(input)
        }
        try await selectionWait { await gate.entered }
        config.profiles[0].spokenFormatting = false
        XCTAssertThrowsError(try session.start(text: "Other", configuration: config, appBundleID: nil))
        XCTAssertTrue(session.configuration?.cleanup.spokenFormatting == true)
        XCTAssertEqual(session.configuration?.whisper.language, "de")
        await gate.open()
        try await selectionWait { await MainActor.run { session.state == .preview } }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.input, raw)
        XCTAssertEqual(session.result?.text, "128, Nicht 256.\n\nVersion 1.2.")
        XCTAssertEqual(session.result?.origin, .formatting)
        session.close()
        XCTAssertNil(session.input); XCTAssertNil(session.configuration); XCTAssertNil(session.result)
    }

    @MainActor func testClosedLateAnswerCannotReplaceNextResult() async throws {
        var config = Config(); config.cleanup.enabled = false
        let session = SelectionCleanupSession(), gate = SelectionTestGate()
        try session.start(text: "Old 128.", configuration: config, appBundleID: nil) { _, input in
            await gate.wait(); return .init(text: input, usedFallback: false, fallbackReason: nil, endpoint: nil, origin: .raw)
        }
        try await selectionWait { await gate.entered }
        session.close()
        try session.start(text: "New 256.", configuration: config, appBundleID: nil)
        try await selectionWait { await MainActor.run { session.state == .preview } }
        await gate.open()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(session.result?.text, "New 256.")
        XCTAssertEqual(session.input, "New 256.")
        XCTAssertEqual(session.result?.origin, .raw)
    }

    @MainActor func testImmediateCloseDoesNotStartCleaner() async throws {
        let session = SelectionCleanupSession()
        var calls = 0
        session.onChange = { if session.state == .processing { session.close() } }
        try session.start(text: "128.", configuration: Config(), appBundleID: nil) { _, input in
            calls += 1; return .init(text: input, usedFallback: false, fallbackReason: nil, endpoint: nil)
        }
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(calls, 0)
        XCTAssertNil(session.result); XCTAssertNil(session.input)
        XCTAssertEqual(session.state, .cancelled)
    }

    @MainActor func testUnverifiedServiceTightensPolicyAfterProfileResolutionWithoutSavingIt() async throws {
        var config = Config(); config.cleanup.localOnly = false; config.cleanup.enabled = false
        var profile = Config.Profile(name: "Manual")
        profile.cleanup = Config.CleanupOptions(config.cleanup); profile.cleanup?.localOnly = false
        config.profiles = [profile]; config.selectedProfileID = profile.id
        let session = SelectionCleanupSession()
        try session.start(text: "128, not 256.", configuration: config, appBundleID: nil, requiresLocalOnly: true) { cleanup, input in
            XCTAssertTrue(cleanup.localOnly)
            return .init(text: input, usedFallback: false, fallbackReason: nil, endpoint: nil, origin: .raw)
        }
        try await selectionWait { await MainActor.run { session.state == .preview } }
        XCTAssertTrue(session.configuration?.cleanup.localOnly == true)
        XCTAssertFalse(config.cleanup.localOnly)
        XCTAssertEqual(config.profiles[0].cleanup?.localOnly, false)
        session.close()
    }
}

private actor SelectionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private func selectionWait(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw NSError(domain: "SelectionTest", code: 1)
}
