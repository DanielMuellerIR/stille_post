import Foundation

public enum HistoryRecleanup {
    public struct Candidate: Sendable {
        public let expected: HistoryStore.Entry
        public let result: CleanupService.Result
        public let durationSec: Double
    }

    public enum Failure: Error, LocalizedError {
        case disabled, unsuccessful
        public var errorDescription: String? {
            L10n.text(self == .disabled ? "core.history.recleanup_disabled" : "core.history.recleanup_failed")
        }
    }

    /// Ein vollständiger Textlauf ohne Audio und ohne Speicherung. Erst eine
    /// spätere ausdrückliche Übernahme darf das bisherige Ergebnis ersetzen.
    public static func run(expected: HistoryStore.Entry, history: HistoryStore,
                           configFile: ConfigFile = ConfigFile(),
                           clean: ((Config.Cleanup, String) async -> CleanupService.Result)? = nil) async throws -> Candidate {
        try Task.checkCancellation()
        let config = try await history.withEditableSnapshotAsync(expected: expected) { try configFile.load() }
        guard config.cleanup.enabled else { throw Failure.disabled }
        try config.validate()
        guard !expected.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unsuccessful }
        try Task.checkCancellation()
        let start = Date()
        let result: CleanupService.Result
        if let clean { result = await clean(config.cleanup, expected.rawText) }
        else { result = await CleanupService(config: config.cleanup).clean(expected.rawText) }
        try Task.checkCancellation()
        guard !result.usedFallback, result.endpoint != nil,
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unsuccessful }
        _ = try await history.withEditableSnapshotAsync(expected: expected) { true }
        return Candidate(expected: expected, result: result, durationSec: Date().timeIntervalSince(start))
    }
}
