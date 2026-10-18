import Foundation

/// Flüchtiger Ausschnitt aus bereits vorhandenen, geordneten Segmentergebnissen.
/// Eine Lücke wird niemals durch nachfolgende Wörter verdeckt.
public struct DictationTranscriptPreview: Equatable, Sendable {
    public let text: String
    public let hasFailedSegment: Bool
    public let isTruncated: Bool
    public init(text: String, hasFailedSegment: Bool = false) {
        isTruncated = text.count > 600
        self.text = String(text.suffix(600))
        self.hasFailedSegment = hasFailedSegment
    }
}
