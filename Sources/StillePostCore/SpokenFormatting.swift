import Foundation

/// Erkennt ausschließlich Absicht aus dem Rohtext. Spätere Modellwörter können
/// keine neue Aktion auslösen; Markierungen tragen nur die erkannten Positionen.
struct SpokenFormattingPlan {
    private struct Node {
        let range: NSRange
        let original: String
        let literal: String?
        let breaks: Int
        let changesFormatting: Bool
        let start: String
        let end: String?
    }
    private let raw: String
    private let namespace: String
    private let nodes: [Node]
    let annotated: String
    let changesFormatting: Bool

    init?(_ raw: String) {
        let source = raw as NSString
        let quotes = Self.quoteRanges(raw)
        let starts = Self.matches(#"\bformat[\s.,:;]+(?:wörtlich[\s.,:;]+anfang|literal[\s.,:;]+start)\b"#, raw)
        let ends = Self.matches(#"\bformat[\s.,:;]+(?:wörtlich[\s.,:;]+ende|literal[\s.,:;]+end)\b"#, raw)
        var protected: [(NSRange, String, Bool)] = []
        for start in starts {
            guard !quotes.contains(where: { Self.overlaps($0, start) }),
                  !protected.contains(where: { Self.overlaps($0.0, start) }) else { continue }
            if let end = ends.first(where: { candidate in
                candidate.location >= NSMaxRange(start) && !quotes.contains(where: { Self.overlaps($0, candidate) })
            }) {
                let range = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
                let body = source.substring(with: NSRange(location: NSMaxRange(start), length: end.location - NSMaxRange(start)))
                protected.append((range, body.trimmingCharacters(in: .whitespacesAndNewlines), true))
            } else {
                let range = NSRange(location: start.location, length: source.length - start.location)
                protected.append((range, source.substring(with: range), false))
            }
        }
        for quote in quotes where !protected.contains(where: { Self.overlaps($0.0, quote) }) {
            protected.append((quote, source.substring(with: quote), false))
        }
        var definitions = protected.map { (range: $0.0, literal: Optional($0.1), breaks: 0, changed: $0.2) }
        let commands = Self.matches(#"\bformat[\s.,:;]+(?:neuer[\s.,:;]+absatz|neue[\s.,:;]+zeile|new[\s.,:;]+paragraph|new[\s.,:;]+line)\b"#, raw)
        for match in commands where !protected.contains(where: { Self.overlaps($0.0, match) }) {
            var range = match
            while NSMaxRange(range) < source.length, ".!?,;:".utf16.contains(source.character(at: NSMaxRange(range))) { range.length += 1 }
            let text = source.substring(with: match).lowercased()
            definitions.append((range, nil, text.contains("absatz") || text.contains("paragraph") ? 2 : 1, true))
        }
        definitions.sort { $0.range.location < $1.range.location }
        guard !definitions.isEmpty else { return nil }
        let namespace = "⟦SP" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var nodes: [Node] = [], annotated = "", cursor = 0
        for (index, value) in definitions.enumerated() {
            guard value.range.location >= cursor else { continue }
            let start = namespace + "N\(index)⟧"
            let end = value.literal == nil ? nil : namespace + "E\(index)⟧"
            annotated += source.substring(with: NSRange(location: cursor, length: value.range.location - cursor))
            annotated += start + (value.literal ?? "") + (end ?? "")
            nodes.append(Node(range: value.range, original: source.substring(with: value.range), literal: value.literal,
                breaks: value.breaks, changesFormatting: value.changed, start: start, end: end))
            cursor = NSMaxRange(value.range)
        }
        annotated += source.substring(from: cursor)
        self.raw = raw; self.namespace = namespace; self.nodes = nodes; self.annotated = annotated
        changesFormatting = nodes.contains { $0.changesFormatting }
        if changesFormatting, render(annotated)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return nil }
    }

    /// Der zusätzliche Abgleich enthält keine künstlichen Markerwörter oder
    /// UUID-Zahlen. Nur außerhalb geschützter Bereiche gelten bestätigte Varianten.
    func expectedForValidation(_ cleanup: Config.Cleanup) -> String {
        let source = raw as NSString
        var result = "", cursor = 0
        for node in nodes {
            result += VocabularyRules.applying(to: source.substring(with: NSRange(location: cursor, length: node.range.location - cursor)), cleanup: cleanup)
            result += node.original
            cursor = NSMaxRange(node.range)
        }
        return result + VocabularyRules.applying(to: source.substring(from: cursor), cleanup: cleanup)
    }

    func modelInput(_ cleanup: Config.Cleanup) -> String {
        let source = raw as NSString
        var result = "", cursor = 0
        for node in nodes {
            result += VocabularyRules.applying(to: source.substring(with: NSRange(location: cursor, length: node.range.location - cursor)), cleanup: cleanup)
            result += node.start + (node.literal ?? "") + (node.end ?? "")
            cursor = NSMaxRange(node.range)
        }
        return result + VocabularyRules.applying(to: source.substring(from: cursor), cleanup: cleanup)
    }

    func restoringLiterals(_ candidate: String) -> String? {
        guard shadow(candidate) != nil else { return nil }
        var result = candidate
        for node in nodes.reversed() {
            guard let literal = node.literal, let end = node.end,
                  let first = result.range(of: node.start), let last = result.range(of: end, range: first.upperBound..<result.endIndex) else { continue }
            result.replaceSubrange(first.upperBound..<last.lowerBound, with: literal)
        }
        return result
    }

    func shadow(_ candidate: String) -> String? { decode(candidate, formatting: false) }
    func render(_ candidate: String) -> String? { decode(candidate, formatting: true) }
    var localText: String {
        render(TranscriptPolish.repairPunctuation(annotated)) ?? render(annotated) ?? raw
    }

    private func decode(_ supplied: String, formatting: Bool) -> String? {
        let candidate = formatting ? supplied.trimmingCharacters(in: .whitespacesAndNewlines) : supplied
        let markers = nodes.flatMap { [$0.start] + ($0.end.map { [$0] } ?? []) }
        guard candidate.components(separatedBy: namespace).count == markers.count + 1 else { return nil }
        var last = candidate.startIndex
        for marker in markers {
            guard candidate.components(separatedBy: marker).count == 2,
                  let range = candidate.range(of: marker, range: last..<candidate.endIndex) else { return nil }
            last = range.upperBound
        }
        var result = "", cursor = candidate.startIndex, skipSpaces = false
        func appendText(_ value: Substring) {
            var text = String(value)
            if skipSpaces { text = String(text.drop(while: { $0 == " " || $0 == "\t" })); skipSpaces = false }
            result += text
        }
        for node in nodes {
            guard let start = candidate.range(of: node.start, range: cursor..<candidate.endIndex) else { return nil }
            appendText(candidate[cursor..<start.lowerBound])
            var end = start.upperBound
            if let marker = node.end {
                guard let range = candidate.range(of: marker, range: end..<candidate.endIndex) else { return nil }
                end = range.upperBound
            }
            if !formatting { result += node.original }
            else if let literal = node.literal { result += literal }
            else {
                while result.last == " " || result.last == "\t" { result.removeLast() }
                result += String(repeating: "\n", count: node.breaks); skipSpaces = true
            }
            cursor = end
        }
        appendText(candidate[cursor...])
        return formatting ? result.trimmingCharacters(in: .whitespaces) : result
    }

    private static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool { NSIntersectionRange(a, b).length > 0 }
    private static func matches(_ pattern: String, _ text: String) -> [NSRange] {
        let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .useUnicodeWordBoundaries])
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }
    private static func quoteRanges(_ text: String) -> [NSRange] {
        let characters = Array(text)
        var positions = [0]
        for character in characters { positions.append(positions.last! + String(character).utf16.count) }
        let pairs: [Character: Character] = ["\"":"\"", "'":"'", "„":"“", "“":"”", "‘":"’", "«":"»"]
        var open: (Int, Character)?, ranges: [NSRange] = []
        for (index, character) in characters.enumerated() {
            if let current = open {
                if character == current.1 {
                    ranges.append(NSRange(location: positions[current.0], length: positions[index + 1] - positions[current.0])); open = nil
                }
            } else if let close = pairs[character] {
                if character == "'", index > 0, characters[index - 1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) { continue }
                open = (index, close)
            }
        }
        if let current = open { ranges.append(NSRange(location: positions[current.0], length: positions.last! - positions[current.0])) }
        return ranges
    }
}
