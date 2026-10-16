import Foundation

public struct DictionaryVariant: Codable, Equatable, Sendable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// Bestätigte Schreibweisen gelten global. Die engere Variantenregel verhindert
/// insbesondere Ersetzungen kurzer Wörter, Zahlen und Verneinungen.
public enum VocabularyRules {
    public enum Failure: Error, LocalizedError {
        case invalidTerm, collision, unsafeVariant, limit

        public var errorDescription: String? {
            switch self {
            case .invalidTerm: return L10n.text("core.vocabulary.invalid_term")
            case .collision: return L10n.text("core.vocabulary.collision")
            case .unsafeVariant: return L10n.text("core.vocabulary.unsafe_variant")
            case .limit: return L10n.text("core.vocabulary.limit")
            }
        }
    }

    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func adding(term: String, variant: String?, to cleanup: Config.Cleanup) throws -> Config.Cleanup {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validTerm(term) else { throw Failure.invalidTerm }
        var result = cleanup
        if let existing = result.dictionary.first(where: { key($0) == key(term) }) {
            guard existing == term else { throw Failure.collision }
        } else {
            result.dictionary.append(term)
        }
        if let source = variant?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
            let rule = DictionaryVariant(source: source, target: term)
            if !result.dictionaryVariants.contains(rule) { result.dictionaryVariants.append(rule) }
        }
        try validate(result)
        return result
    }

    public static func validate(_ cleanup: Config.Cleanup) throws {
        guard cleanup.dictionary.count <= 500, cleanup.dictionaryVariants.count <= 100 else { throw Failure.limit }
        guard cleanup.dictionary.allSatisfy(validTerm) else { throw Failure.invalidTerm }
        let terms = Dictionary(grouping: cleanup.dictionary, by: key)
        guard terms.values.allSatisfy({ Set($0).count == 1 }) else { throw Failure.collision }
        var sources = Set<String>()
        for rule in cleanup.dictionaryVariants {
            let parts = rule.source.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            let target = key(rule.target)
            let isTechnicalSpelling = Config.Cleanup.defaultDictionary.contains(rule.target)
                || (rule.target.contains(where: \.isLowercase) && rule.target.dropFirst().contains(where: \.isUppercase))
            guard isTechnicalSpelling,
                  (2...3).contains(parts.count), parts.allSatisfy({ $0.count >= 3 && $0.allSatisfy(\.isLetter) }),
                  (6...40).contains(rule.target.count), rule.target.allSatisfy(\.isLetter),
                  cleanup.dictionary.contains(rule.target),
                  !parts.contains(where: { protectedWords.contains(key($0)) }),
                  !protectedWords.contains(target),
                  spellingDistance(key(parts.joined()), target) <= 1 else { throw Failure.unsafeVariant }
            guard sources.insert(key(rule.source)).inserted else { throw Failure.collision }
        }
        // Überlappende Quellen würden die Bedeutung von Reihenfolge abhängig machen.
        // Einwort-Ziele können keine weitere Mehrwort-Quelle auslösen.
        for (index, rule) in cleanup.dictionaryVariants.enumerated() {
            for other in cleanup.dictionaryVariants.dropFirst(index + 1) {
                guard !key(rule.source).contains(key(other.source)),
                      !key(other.source).contains(key(rule.source)) else { throw Failure.collision }
            }
        }
    }

    public static func applying(to text: String, cleanup: Config.Cleanup) -> String {
        guard (try? validate(cleanup)) != nil, !cleanup.dictionaryVariants.isEmpty else { return text }
        let alternatives = cleanup.dictionaryVariants.map { NSRegularExpression.escapedPattern(for: $0.source) }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let original = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let matched = original.substring(with: match.range)
            if let target = cleanup.dictionaryVariants.first(where: { key($0.source) == key(matched) })?.target,
               let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: target)
            }
        }
        return result
    }

    private static func validTerm(_ term: String) -> Bool {
        !term.isEmpty && term.count <= 80 && term == term.trimmingCharacters(in: .whitespacesAndNewlines)
            && term.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            && !term.contains("\n") && !term.contains("\r")
    }

    private static let protectedWords: Set<String> = [
        "nicht", "kein", "keine", "keinen", "keinem", "keiner", "keines", "nie", "niemals", "ohne",
        "not", "no", "never", "without", "neither", "nor", "dont", "cannot",
        "der", "die", "das", "ein", "eine", "und", "oder", "aber", "ist", "sind", "mit", "von", "für",
        "the", "a", "an", "and", "or", "but", "is", "are", "with", "from", "for"
    ]

    private static func spellingDistance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        guard abs(a.count - b.count) <= 1 else { return 2 }
        var row = Array(0...b.count)
        for (i, char) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (char == other ? 0 : 1)))
            }
            row = next
        }
        return row.last ?? 0
    }
}
