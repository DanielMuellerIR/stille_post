import Foundation
@testable import StillePostCore

// Prüft das produktive Ansichtsmodell ohne Fenster, Aufnahme, Netz oder Clipboard.
@main struct DiagnosticsRegression {
    @MainActor static func main() async throws {
        var config = Config()
        config.whisper.language = "de"
        config.cleanup.enabled = false
        let gate = DiagnosisGate()
        let service = DiagnosticsService(dependencies: .init(
            whisper: { value in
                if value.language == "de" { await gate.wait(); return .ready }
                return .unexpectedResponse
            }, executable: { _ in true }, model: { .installed(path: $0, bytes: 1) },
            cleanup: { _, _ in .ready }, hasRemoteKey: { _ in fatalError("Kein Schlüsselzugriff erwartet") },
            bridgeToken: { fatalError("Kein Tokenzugriff erwartet") }))
        let model = DiagnosticsModel(configuration: { config }, bridgeState: { .unknown }, onAction: { _ in }, service: service)
        func wait(_ condition: () async -> Bool) async throws {
            for _ in 0..<2000 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw Failure.timeout
        }
        model.start()
        try await wait { await gate.entered }
        guard model.checking, model.report == nil else { throw Failure.state }
        config.whisper.language = "en"
        model.start()
        try await wait { model.report != nil }
        guard !model.checking, model.profile.contains("en"),
              model.report?.findings.contains(where: { $0.code == "whisper_unexpected" }) == true else { throw Failure.state }
        await gate.open()
        try await Task.sleep(nanoseconds: 20_000_000)
        guard model.report?.findings.contains(where: { $0.code == "whisper_unexpected" }) == true else { throw Failure.stale }
        model.start(); model.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        guard model.report == nil, !model.checking, model.note == L10n.text("diagnosis.cancelled") else { throw Failure.cancel }
        print("PASS Diagnose-Ansichtsmodell: bedienbar während Await, neuester Auftrag, gefrorenes Profil, Abbruch ohne spätes Ergebnis")
    }
    enum Failure: Error { case timeout, state, stale, cancel }
}
private actor DiagnosisGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
