import Foundation

/// Erkennt ausschließlich Absicht aus dem vollständigen Rohtext. Spätere
/// Modellwörter können keine Aktion auslösen; Marker tragen erkannte Positionen.
struct SpokenFormattingPlan {
    private enum Action {
        case literal(String, prefix: String = "", suffix: String = "")
        case lineBreak(Int)
        case listStart, listPoint, listEnd

        var literal: String? {
            if case .literal(let text, _, _) = self { return text }
            return nil
        }
    }
    private struct Definition {
        let range: NSRange
        let action: Action
        let changed: Bool
    }
    private struct Node {
        let range: NSRange
        let original: String
        let action: Action
        let start: String
        let end: String?
    }
    private struct Command {
        enum Kind { case listStart, listPoint, listEnd, quoteStart, quoteEnd, literalStart, literalEnd }
        let range: NSRange
        let kind: Kind
        let german: Bool
    }
    private let raw: String
    private let namespace: String
    private let nodes: [Node]
    let annotated: String
    let changesFormatting: Bool

    init?(_ raw: String) {
        let source = raw as NSString
        var definitions = Self.protectedDefinitions(raw)
        let commands = Self.commands(raw).filter { command in
            !definitions.contains { Self.overlaps($0.range, command.range) }
        }
        Self.addLists(commands.filter { command in
            !definitions.contains { Self.overlaps($0.range, command.range) }
        }, source: source, to: &definitions)
        for match in Self.lineCommands(raw) where !definitions.contains(where: { Self.overlaps($0.range, match) }) {
            let text = source.substring(with: match).lowercased()
            definitions.append(Definition(range: Self.withPunctuation(match, source),
                action: .lineBreak(text.contains("absatz") || text.contains("paragraph") ? 2 : 1), changed: true))
        }
        definitions.sort { $0.range.location < $1.range.location }
        guard !definitions.isEmpty else { return nil }
        let namespace = "⟦SP" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var nodes: [Node] = [], annotated = "", cursor = 0
        for (index, value) in definitions.enumerated() {
            precondition(value.range.location >= cursor)
            let start = namespace + "N\(index)⟧"
            let end = value.action.literal == nil ? nil : namespace + "E\(index)⟧"
            annotated += source.substring(with: NSRange(location: cursor, length: value.range.location - cursor))
            annotated += start + (value.action.literal ?? "") + (end ?? "")
            nodes.append(Node(range: value.range, original: source.substring(with: value.range),
                action: value.action, start: start, end: end))
            cursor = NSMaxRange(value.range)
        }
        annotated += source.substring(from: cursor)
        self.raw = raw; self.namespace = namespace; self.nodes = nodes; self.annotated = annotated
        changesFormatting = definitions.contains { $0.changed }
        if changesFormatting, !Self.hasPayload(render(annotated) ?? "") { return nil }
    }

    /// Der zusätzliche Gesamtvergleich enthält weder künstliche Markerwörter
    /// noch UUID-Zahlen. Bestätigte Varianten gelten nur außerhalb von Literalen.
    func expectedForValidation(_ cleanup: Config.Cleanup) -> String {
        transformOutsideLiterals(cleanup, markers: false)
    }

    func modelInput(_ cleanup: Config.Cleanup) -> String {
        transformOutsideLiterals(cleanup, markers: true)
    }

    private func transformOutsideLiterals(_ cleanup: Config.Cleanup, markers: Bool) -> String {
        let source = raw as NSString
        var result = "", cursor = 0
        for node in nodes {
            result += VocabularyRules.applying(to: source.substring(with: NSRange(location: cursor, length: node.range.location - cursor)), cleanup: cleanup)
            result += markers ? node.start + (node.action.literal ?? "") + (node.end ?? "") : node.original
            cursor = NSMaxRange(node.range)
        }
        return result + VocabularyRules.applying(to: source.substring(from: cursor), cleanup: cleanup)
    }

    func restoringLiterals(_ candidate: String, cleanup: Config.Cleanup = Config.Cleanup()) -> String? {
        guard let spans = markerSpans(candidate), let expected = markerSpans(modelInput(cleanup)),
              zip(expected, spans).allSatisfy({ CleanupService.preservesFormattingPosition(raw: $0.0, cleaned: $0.1) }) else { return nil }
        var result = candidate
        for node in nodes.reversed() {
            guard let literal = node.action.literal, let end = node.end,
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

    /// Nur die äußeren Zwischenräume prüfen: Literalinhalt wird aus Raw
    /// rekonstruiert. Jeder Marker muss unverändert einmal in derselben Folge
    /// vorkommen; zusätzlich darf kein neuer fremder SP-Marker auftauchen.
    private func markerSpans(_ candidate: String) -> [String]? {
        let markers = nodes.flatMap { [$0.start] + ($0.end.map { [$0] } ?? []) }
        guard candidate.components(separatedBy: namespace).count == markers.count + 1,
              candidate.components(separatedBy: "⟦SP").count == annotated.components(separatedBy: "⟦SP").count else { return nil }
        var last = candidate.startIndex
        for marker in markers {
            guard candidate.components(separatedBy: marker).count == 2,
                  let range = candidate.range(of: marker, range: last..<candidate.endIndex) else { return nil }
            last = range.upperBound
        }
        var spans: [String] = [], cursor = candidate.startIndex
        for node in nodes {
            guard let start = candidate.range(of: node.start, range: cursor..<candidate.endIndex) else { return nil }
            spans.append(String(candidate[cursor..<start.lowerBound]))
            cursor = start.upperBound
            if let end = node.end {
                guard let range = candidate.range(of: end, range: cursor..<candidate.endIndex) else { return nil }
                cursor = range.upperBound
            }
        }
        spans.append(String(candidate[cursor...]))
        return spans
    }

    private func decode(_ supplied: String, formatting: Bool) -> String? {
        let candidate = formatting ? supplied.trimmingCharacters(in: .whitespacesAndNewlines) : supplied
        guard markerSpans(candidate) != nil else { return nil }
        var result = "", cursor = candidate.startIndex, skipSpaces = false
        func appendText(_ value: Substring) {
            var text = String(value)
            if skipSpaces { text = String(text.drop(while: { $0 == " " || $0 == "\t" })); skipSpaces = false }
            result += text
        }
        func trimSpaces() {
            while result.last == " " || result.last == "\t" { result.removeLast() }
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
            else {
                switch node.action {
                case .literal(let text, let prefix, let suffix): result += prefix + text + suffix
                case .lineBreak(let count):
                    trimSpaces(); result += String(repeating: "\n", count: count); skipSpaces = true
                case .listStart, .listPoint:
                    trimSpaces()
                    if !result.isEmpty, result.last != "\n" { result += "\n" }
                    result += "• "; skipSpaces = true
                case .listEnd:
                    trimSpaces(); result += "\n"; skipSpaces = true
                }
            }
            cursor = end
        }
        appendText(candidate[cursor...])
        return formatting ? result.trimmingCharacters(in: .whitespaces) : result
    }

    private static func protectedDefinitions(_ raw: String) -> [Definition] {
        let source = raw as NSString, writtenQuotes = quoteRanges(raw)
        let controls = commands(raw).filter { command in
            [.literalStart, .literalEnd, .quoteStart, .quoteEnd].contains(command.kind)
                && !writtenQuotes.contains { overlaps($0, command.range) }
        }
        var result: [Definition] = [], cursor = 0
        for (index, start) in controls.enumerated() where start.range.location >= cursor {
            if start.kind == .literalEnd { continue }
            if start.kind == .quoteEnd {
                result.append(Definition(range: start.range, action: .literal(source.substring(with: start.range)), changed: false))
                continue
            }
            var closing: Command?, nested = false
            if start.kind == .literalStart {
                closing = controls.dropFirst(index + 1).first { $0.kind == .literalEnd }
            } else {
                var depth = 1
                for next in controls.dropFirst(index + 1) {
                    if next.kind == .quoteStart { depth += 1; nested = true }
                    if next.kind == .quoteEnd { depth -= 1 }
                    if depth == 0 { closing = next; break }
                }
            }
            let end = closing.map { NSMaxRange($0.range) } ?? source.length
            let range = NSRange(location: start.range.location, length: end - start.range.location)
            let bodyEnd = closing?.range.location ?? end
            let body = source.substring(with: NSRange(location: NSMaxRange(start.range), length: bodyEnd - NSMaxRange(start.range)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if closing != nil, !nested, start.kind == .literalStart || hasPayload(body) {
                let prefix = start.kind == .literalStart ? "" : start.german ? "„" : "“"
                let suffix = start.kind == .literalStart ? "" : start.german ? "“" : "”"
                result.append(Definition(range: range, action: .literal(body, prefix: prefix, suffix: suffix), changed: true))
            } else {
                result.append(Definition(range: range, action: .literal(source.substring(with: range)), changed: false))
            }
            cursor = end
        }
        for quote in writtenQuotes where !result.contains(where: { overlaps($0.range, quote) }) {
            result.append(Definition(range: quote, action: .literal(source.substring(with: quote)), changed: false))
        }
        return result
    }

    private static func commands(_ raw: String) -> [Command] {
        let source = raw as NSString
        let forms: [(String, Command.Kind, Bool)] = [
            ("liste[\\s.,:;]+anfang", .listStart, true), ("list[\\s.,:;]+start", .listStart, false),
            ("listenpunkt", .listPoint, true), ("bullet[\\s.,:;]+point", .listPoint, false),
            ("liste[\\s.,:;]+ende", .listEnd, true), ("list[\\s.,:;]+end", .listEnd, false),
            ("anf(?:ü|u\u{0308})hrungszeichen[\\s.,:;]+anfang", .quoteStart, true), ("quote[\\s.,:;]+start", .quoteStart, false),
            ("anf(?:ü|u\u{0308})hrungszeichen[\\s.,:;]+ende", .quoteEnd, true), ("quote[\\s.,:;]+end", .quoteEnd, false),
            ("w(?:ö|o\u{0308})rtlich[\\s.,:;]+anfang", .literalStart, true), ("literal[\\s.,:;]+start", .literalStart, false),
            ("w(?:ö|o\u{0308})rtlich[\\s.,:;]+ende", .literalEnd, true), ("literal[\\s.,:;]+end", .literalEnd, false)
        ]
        return forms.flatMap { form in
            matches("\\bformat[\\s.,:;]+(?:" + form.0 + ")\\b", raw).map {
                Command(range: [.quoteEnd, .literalStart, .literalEnd].contains(form.1) ? $0 : withPunctuation($0, source), kind: form.1, german: form.2)
            }
        }.sorted { $0.range.location < $1.range.location }
    }

    private static func addLists(_ commands: [Command], source: NSString, to definitions: inout [Definition]) {
        let lists = commands.filter { $0.kind == .listStart || $0.kind == .listPoint || $0.kind == .listEnd }
        var cursor = 0
        for (index, start) in lists.enumerated() where start.range.location >= cursor {
            guard start.kind == .listStart else {
                definitions.append(Definition(range: start.range, action: .literal(source.substring(with: start.range)), changed: false)); continue
            }
            var depth = 1, nested = false, closing: Command?, items = [start]
            for next in lists.dropFirst(index + 1) {
                if next.kind == .listStart { depth += 1; nested = true }
                if next.kind == .listEnd { depth -= 1 }
                if depth == 0 { closing = next; break }
                if next.kind == .listPoint { items.append(next) }
            }
            let end = closing.map { NSMaxRange($0.range) } ?? source.length
            let range = NSRange(location: start.range.location, length: end - start.range.location)
            let boundaries = items.dropFirst().map { $0.range.location } + [closing?.range.location ?? end]
            let nonempty = zip(items, boundaries).allSatisfy { item, boundary in
                let bodyRange = NSRange(location: NSMaxRange(item.range), length: boundary - NSMaxRange(item.range))
                var body = source.substring(with: bodyRange) as NSString
                for command in lineCommands(body as String).reversed() {
                    let global = NSRange(location: bodyRange.location + command.location, length: command.length)
                    if !definitions.contains(where: { overlaps($0.range, global) }) {
                        body = body.replacingCharacters(in: command, with: "") as NSString
                    }
                }
                return hasPayload(body as String)
            }
            if nested || !nonempty {
                definitions.removeAll { overlaps($0.range, range) }
                definitions.append(Definition(range: range, action: .literal(source.substring(with: range)), changed: false))
            } else {
                for (itemIndex, item) in items.enumerated() {
                    definitions.append(Definition(range: item.range, action: itemIndex == 0 ? .listStart : .listPoint, changed: true))
                }
                if let closing { definitions.append(Definition(range: closing.range, action: .listEnd, changed: true)) }
            }
            cursor = end
        }
    }

    private static func lineCommands(_ text: String) -> [NSRange] {
        matches(#"\bformat[\s.,:;]+(?:neuer[\s.,:;]+absatz|neue[\s.,:;]+zeile|new[\s.,:;]+paragraph|new[\s.,:;]+line)\b"#, text)
    }
    private static func hasPayload(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }
    private static func withPunctuation(_ match: NSRange, _ source: NSString) -> NSRange {
        var range = match
        while NSMaxRange(range) < source.length, ".!?,;:".utf16.contains(source.character(at: NSMaxRange(range))) { range.length += 1 }
        return range
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
