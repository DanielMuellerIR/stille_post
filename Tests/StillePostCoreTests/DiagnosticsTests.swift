import XCTest
@testable import StillePostCore

final class DiagnosticsTests: XCTestCase {
    func testDisabledAutostartReportsOneBlockerAndSkipsUnusedFiles() async throws {
        let f = DiagnosticFixture()
        f.config.whisper.autostart = false; f.health = .unavailable
        let report = try await f.scan()
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertEqual(report.findings.filter { $0.level == .problem }.map(\.code), ["whisper_no_autostart"])
        XCTAssertEqual(f.fileChecks, 0)
    }
    func testRunningAndLoadingServersOnlyWarnAboutColdStartFiles() async throws {
        for health in [WhisperClient.Health.ready, .loading] {
            let f = DiagnosticFixture(); f.health = health; f.filesPresent = false
            let report = try await f.scan()
            XCTAssertEqual(report.problemCount, 0)
            XCTAssertTrue(report.findings.contains { $0.code == "binary_cold_start" && $0.level == .warning })
            XCTAssertTrue(report.findings.contains { $0.code == "model_cold_start" && $0.level == .warning })
        }
    }
    func testUnexpectedHttpServiceIsABlockerEvenWithAutostart() async throws {
        let f = DiagnosticFixture(); f.health = .unexpectedResponse
        let report = try await f.scan()
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertTrue(report.findings.contains { $0.code == "whisper_unexpected" && $0.level == .problem })
    }
    func testAutostartNeedsExecutableAndIndependentModel() async throws {
        let f = DiagnosticFixture(); f.health = .unavailable; f.filesPresent = false
        var report = try await f.scan()
        XCTAssertEqual(report.problemCount, 2)
        f.filesPresent = true; f.borrowedModel = true
        report = try await f.scan()
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertTrue(report.findings.contains { $0.code == "model_borrowed" })
    }
    func testFallbackKeepsChainUsableAndIdentifiesMissingPrimaryModel() async throws {
        let f = DiagnosticFixture(); f.config.cleanup.enabled = true
        var fallback = Config.Cleanup.Endpoint(); fallback.ollamaURL = "http://127.0.0.1:19992"
        f.config.cleanup.fallbacks = [fallback]
        f.endpoint = { $0.ollamaURL == fallback.ollamaURL ? .ready : .modelMissing }
        let report = try await f.scan()
        XCTAssertEqual(report.problemCount, 0)
        XCTAssertTrue(report.findings.contains { $0.id == "cleanup.0" && $0.code == "cleanup_model_missing" })
        XCTAssertTrue(report.findings.contains { $0.id == "cleanup.1" && $0.code == "cleanup_fallback_ready" })
    }
    func testLocalProfileFiltersBeforeProbeOrKeyRead() async throws {
        let f = DiagnosticFixture(); f.config.cleanup.enabled = true; f.config.cleanup.localOnly = true
        f.config.cleanup.provider = "openai"; f.config.cleanup.remote.baseURL = "https://example.invalid/v1"
        var fallback = Config.Cleanup.Endpoint(); fallback.ollamaURL = "http://127.0.0.1:19992"
        f.config.cleanup.fallbacks = [fallback]
        let report = try await f.scan()
        XCTAssertEqual(f.keyReads, 0)
        XCTAssertEqual(f.probedURLs, [fallback.ollamaURL])
        XCTAssertEqual(report.problemCount, 0)
        XCTAssertTrue(report.findings.contains { $0.code == "cleanup_blocked_local" })
    }
    func testExternalConfigurationRemainsExplicitlyUnverified() async throws {
        let f = DiagnosticFixture(); f.config.cleanup.enabled = true
        f.config.cleanup.provider = "openai"; f.config.cleanup.remote.baseURL = "https://example.invalid/v1"
        f.config.cleanup.localOnly = false
        f.config.cleanup.remote.model = "synthetic"
        let report = try await f.scan()
        XCTAssertEqual(f.keyReads, 1); XCTAssertTrue(f.probedURLs.isEmpty)
        XCTAssertEqual(report.problemCount, 0); XCTAssertTrue(report.hasUnknowns)
        XCTAssertTrue(report.findings.contains { $0.code == "cleanup_remote_unverified" && $0.level == .unknown })
    }
    func testNoUsableCleanupIsOneProblemAndDisabledBridgeNeverReadsToken() async throws {
        let f = DiagnosticFixture(); f.config.cleanup.enabled = true; f.endpoint = { _ in .unreachable }
        let report = try await f.scan()
        XCTAssertEqual(report.problemCount, 1)
        XCTAssertEqual(f.tokenReads, 0)
        XCTAssertTrue(report.findings.contains { $0.code == "cleanup_none" })
    }
    func testBridgeDistinguishesMissingTokenKeychainFailureAndStoppedListener() async throws {
        for token in [DiagnosticsService.TokenState.missing, .failed, .present] {
            let f = DiagnosticFixture(); f.config.bridge.enabled = true; f.token = token
            var context = DiagnosticContext(); context.bridge = .stopped
            let report = try await f.scan(context: context)
            XCTAssertEqual(report.problemCount, token == .present ? 1 : 2)
            XCTAssertEqual(f.tokenReads, 1)
            XCTAssertTrue(report.findings.contains { $0.code == "bridge_stopped" })
        }
    }
    func testDeniedMicrophoneMissingDeviceAndUnreadableHoldAreConcreteBlockers() async throws {
        let f = DiagnosticFixture(); f.config.hotkeyMode = .hold
        var context = DiagnosticContext(); context.microphone = .denied; context.selectedInputAvailable = false
        context.accessibility = false; context.keyboardReadable = false
        let report = try await f.scan(context: context)
        XCTAssertEqual(report.problemCount, 3)
        XCTAssertEqual(Set(report.findings.filter { $0.level == .problem }.map(\.code)), ["microphone_denied", "device_missing", "keyboard_missing"])
    }
    func testReadableKeyboardWorksWithoutAccessibilityAndUnknownContextDoesNotClaimPermission() async throws {
        let f = DiagnosticFixture(); f.config.hotkeyMode = .hold
        var context = DiagnosticContext(); context.keyboardReadable = true; context.accessibility = false
        let report = try await f.scan(context: context)
        XCTAssertEqual(report.problemCount, 0)
        XCTAssertTrue(report.findings.contains { $0.code == "keyboard_ready" })
        XCTAssertTrue(report.findings.contains { $0.code == "microphone_unknown" && $0.level == .unknown })
    }
    func testReportNeverExportsConfigurationPathsCredentialsOrArbitraryVersion() async throws {
        let f = DiagnosticFixture(); f.config.whisper.serverURL = "http://user:synthetic-secret@192.0.2.1:9090"
        f.config.whisper.binaryPath = "/private/synthetic-secret/whisper"
        f.config.whisper.modelPath = "/private/synthetic-secret/model"
        let report = try await f.scan()
        let exported = report.export(version: "synthetic-secret")
        for forbidden in ["synthetic-secret", "192.0.2.1", "/private/", "user:"] { XCTAssertFalse(exported.contains(forbidden)) }
        XCTAssertTrue(exported.contains("whisper_invalid"))
        XCTAssertEqual(f.healthChecks, 0)
    }
    func testCancelledCheckMakesNoProbes() async throws {
        let f = DiagnosticFixture()
        let gate = DiagnosticGate()
        let task = Task { await gate.wait(); return try await f.scan() }
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Abgebrochene Prüfung liefert Bericht") }
        catch is CancellationError {}
        XCTAssertEqual(f.healthChecks, 0); XCTAssertEqual(f.tokenReads, 0)
    }
}

private final class DiagnosticFixture {
    var config = Config()
    var health: WhisperClient.Health = .ready
    var filesPresent = true, borrowedModel = false
    var fileChecks = 0, healthChecks = 0, keyReads = 0, tokenReads = 0
    var probedURLs: [String] = []
    var token: DiagnosticsService.TokenState = .present
    var endpoint: (Config.Cleanup.Endpoint) -> CleanupService.EndpointCheck = { _ in .ready }
    init() { config.cleanup.enabled = false; config.whisper.language = "de" }
    func scan(context: DiagnosticContext = .init()) async throws -> DiagnosticReport {
        let service = DiagnosticsService(dependencies: .init(
            whisper: { _ in self.healthChecks += 1; return self.health },
            executable: { _ in self.fileChecks += 1; return self.filesPresent },
            model: { path in
                self.fileChecks += 1
                return self.borrowedModel ? .borrowed(path: path, target: "synthetic") : (self.filesPresent ? .installed(path: path, bytes: 1) : .missing(path: path))
            }, cleanup: { _, endpoint in self.probedURLs.append(endpoint.ollamaURL); return self.endpoint(endpoint) },
            hasRemoteKey: { _ in self.keyReads += 1; return true },
            bridgeToken: { self.tokenReads += 1; return self.token }))
        return try await service.scan(configuration: config, context: context)
    }
}

private actor DiagnosticGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
