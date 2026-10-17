import Foundation

/// Hält nur bestätigte, verwendbare Ergebnisse bis zum Beenden der App.
/// Absichtlich ohne Datei- oder Codable-Schnittstelle.
public struct TransientResultStore {
    public struct Result: Equatable {
        public let text: String
        public let rawFallback: Bool
        public let note: String?

        public init?(text: String, rawFallback: Bool, failed: Bool = false, note: String? = nil) {
            guard !failed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.text = text
            self.rawFallback = rawFallback
            self.note = note
        }
    }

    public private(set) var last: Result?

    public init() {}

    @discardableResult
    public mutating func accept(text: String, rawFallback: Bool, failed: Bool = false, note: String? = nil) -> Result? {
        guard let result = Result(text: text, rawFallback: rawFallback, failed: failed, note: note) else { return nil }
        last = result
        return result
    }
}
