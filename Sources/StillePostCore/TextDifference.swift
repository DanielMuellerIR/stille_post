import Foundation

/// Verlustfreier Wortvergleich mit fest begrenzter Matrix. Große vollständig
/// geänderte Texte bleiben als vollständige Alt-/Neufassung lesbar.
public enum TextDifference {
    public enum Kind: Sendable { case unchanged, removed, added }
    public struct Segment: Equatable, Sendable {
        public var kind: Kind
        public var text: String
    }
    public struct Result: Sendable {
        public let before: String
        public let after: String
        public let segments: [Segment]
        public let isSummarized: Bool
    }

    public static func compare(_ before: String, _ after: String) throws -> Result {
        try Task.checkCancellation()
        if HistoryStore.sameText(before, after) {
            return Result(before: before, after: after, segments: [.init(kind: .unchanged, text: before)], isSummarized: false)
        }
        guard let old = try tokens(before), let new = try tokens(after) else {
            return Result(before: before, after: after, segments: [], isSummarized: true)
        }
        var prefix = 0
        while prefix < min(old.count, new.count), HistoryStore.sameText(old[prefix], new[prefix]) {
            if prefix % 256 == 0 { try Task.checkCancellation() }
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              HistoryStore.sameText(old[old.count - suffix - 1], new[new.count - suffix - 1]) {
            if suffix % 256 == 0 { try Task.checkCancellation() }
            suffix += 1
        }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        let rows = oldEnd - prefix + 1, columns = newEnd - prefix + 1
        guard rows <= 2_000_000 / columns else {
            return Result(before: before, after: after, segments: [], isSummarized: true)
        }
        var matrix = [UInt32](repeating: 0, count: rows * columns)
        if rows > 1 && columns > 1 {
            for row in stride(from: rows - 2, through: 0, by: -1) {
                try Task.checkCancellation()
                for column in stride(from: columns - 2, through: 0, by: -1) {
                    let offset = row * columns + column
                    if HistoryStore.sameText(old[prefix + row], new[prefix + column]) {
                        matrix[offset] = matrix[offset + columns + 1] + 1
                    } else {
                        matrix[offset] = max(matrix[offset + columns], matrix[offset + 1])
                    }
                }
            }
        }
        var segments: [Segment] = []
        func append(_ kind: Kind, _ text: String) {
            guard !text.isEmpty else { return }
            if segments.last?.kind == kind { segments[segments.count - 1].text.append(text) }
            else { segments.append(Segment(kind: kind, text: text)) }
        }
        for token in old.prefix(prefix) { append(.unchanged, token) }
        var row = 0, column = 0
        while row < rows - 1 || column < columns - 1 {
            if (row + column) % 256 == 0 { try Task.checkCancellation() }
            if row < rows - 1, column < columns - 1,
               HistoryStore.sameText(old[prefix + row], new[prefix + column]) {
                append(.unchanged, old[prefix + row]); row += 1; column += 1
            } else if row < rows - 1 && (column == columns - 1 || matrix[(row + 1) * columns + column] >= matrix[row * columns + column + 1]) {
                append(.removed, old[prefix + row]); row += 1
            } else {
                append(.added, new[prefix + column]); column += 1
            }
        }
        for token in old.suffix(suffix) { append(.unchanged, token) }
        try Task.checkCancellation()
        return Result(before: before, after: after, segments: segments, isSummarized: false)
    }

    private static func tokens(_ text: String) throws -> [String]? {
        guard text.utf8.count <= 2_000_000 else { return nil }
        enum Category { case word, whitespace, punctuation }
        func category(_ character: Character) -> Category {
            if character.isWhitespace { return .whitespace }
            if character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }) { return .word }
            return .punctuation
        }
        var result: [String] = []
        var start = text.startIndex
        var prior: Category?
        var count = 0
        for index in text.indices {
            count += 1
            if count % 256 == 0 { try Task.checkCancellation() }
            // Auch ein einzelnes Wort oder eine riesige Leerraumfolge hat ein
            // begrenztes Scanbudget; die vollständigen Texte bleiben im Ergebnis.
            if count > 250_000 { return nil }
            let current = category(text[index])
            if let prior, prior != current || current == .punctuation {
                result.append(String(text[start..<index]))
                if result.count > 40_000 { return nil }
                start = index
            }
            prior = current
        }
        if start < text.endIndex { result.append(String(text[start...])) }
        return result
    }
}
