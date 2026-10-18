import Foundation

/// Herkunft der ausgegebenen Wörter und ihrer bewussten lokalen Verarbeitung.
public enum TranscriptOrigin: String, Codable, Sendable {
    case cleanup, rawFallback, manual, raw, formatting
}
