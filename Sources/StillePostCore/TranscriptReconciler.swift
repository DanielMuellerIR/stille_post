import Foundation

/// Prüft, welche Änderungen der Bereinigung durch den Rohtext gedeckt sind.
enum TranscriptReconciler {
    /// Gleicht die LLM-Ausgabe mit dem Rohtext ab — NICHT mehr alles-oder-nichts:
    ///
    /// Früher verwarf ein einziges verändertes Wort die komplette Bereinigung —
    /// inklusive aller korrekten Satzzeichen-Korrekturen im selben Durchlauf. Jetzt
    /// wird der Text an Satzzeichen in Satzteile ("Klauseln") zerlegt und nur der
    /// betroffene Satzteil auf die Roh-Wörter zurückgesetzt.
    ///
    /// Erlaubte Abweichungen je Ausrichtungslücke (via LCS-Anker):
    ///  - Eindeutige Sprechpausen und unmittelbare wortgleiche Wiederholungen
    ///    löschen; andere Löschungen setzen den betroffenen Satzteil zurück.
    ///  - Reine Wort-Trennung/-Fusion ("dauer haft").
    ///  - Ein Tippfehler/Verhörer (Editierabstand 1) und kurze Flexionsendungen.
    ///  - NEU: gleich klingende Wörter (Kölner Phonetik, "Rack" -> "RAG").
    ///  - NEU: Wörterbuch-Fachbegriffe, wenn sie ähnlich klingen ("Mini Macs" ->
    ///    "MiniMax"). `dictionary` enthält dafür normalisierte Begriffe
    ///    (siehe `normalizedDictionary`).
    ///
    /// Harte Gesamtgrenzen führen weiter zum kompletten Rohtext-Fallback:
    /// Markdown-Strukturen, Längenkorridor, Korrektur-Budget (schleichendes
    /// Umschreiben) und mehr als die Hälfte zurückgesetzter Satzteile.
    static func reconcile(raw: String, cleaned: String,
                          dictionary: Set<String> = []) -> CleanupService.Reconciliation {
        if cleaned.isEmpty { return .rejected(reason: L10n.text("core.cleanup.empty")) }
        // Struktur-Prüfung: Gesprochene Sprache enthält keine Markdown-Syntax.
        // Tauchen Code-Zäune, Überschriften oder Tabellen NEU in der Ausgabe auf,
        // hat das Modell "geantwortet" (Doku/Beispiele generiert) statt geputzt.
        for marker in ["```", "\n#", "|---", "| ---"] {
            if cleaned.contains(marker), !raw.contains(marker) {
                return .rejected(reason: L10n.format(
                    "core.cleanup.markdown",
                    marker.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
        // Längenkorridor: Bei sehr kurzen Eingaben ist das Verhältnis statistisch
        // wackelig — dort erlauben wir mehr Spielraum ("ähm ja Punkt" -> "Ja.").
        let rawCount = Double(raw.count)
        let cleanedCount = Double(cleaned.count)
        let lowerBound = rawCount < 60 ? 0.2 : 0.5
        let upperBound = rawCount < 60 ? 3.0 : 1.5
        let ratio = cleanedCount / rawCount
        if ratio < lowerBound {
            return .rejected(reason: L10n.format("core.cleanup.too_short", ratio * 100))
        }
        if ratio > upperBound {
            return .rejected(reason: L10n.format("core.cleanup.too_long", ratio * 100))
        }

        let rawTokens = tokens(in: raw)
        let cleanTokens = tokens(in: cleaned)
        let n = rawTokens.count, m = cleanTokens.count
        // Enthält die Ausgabe kein einziges Wort mehr, der Rohtext aber schon,
        // ist das keine Bereinigung: Der Längenkorridor allein lässt so etwas
        // durch (aus „kein“ wird „.“ — 25 % Länge liegt bei kurzen Eingaben im
        // erlaubten Bereich), und die Sperrlisten-Prüfung käme nie zum Zug.
        // Nur wenn auch der Rohtext wortlos war (reine Satzzeichen), darf die
        // wortlose Ausgabe stehen bleiben.
        if m == 0 {
            if n > 0 { return .rejected(reason: L10n.text("core.cleanup.no_words")) }
            return .accepted(text: cleaned, revertedClauses: 0)
        }

        // Anker = Wortpaare einer längsten gemeinsamen Teilfolge (LCS). Früher
        // stand hier eine volle (n+1)×(m+1)-Tabelle — bei Mehrtausend-Wort-
        // Diktaten Hunderte MB Speicher, was die App unter Druck setzen oder
        // beenden konnte. `lcsAnchors` rechnet nach Hirschberg (Teile-und-
        // herrsche mit zwei Zeilen je Ebene): gleiche O(n·m)-Zeit, aber nur
        // O(n+m) Speicher. Für die heißen Vergleichsschleifen werden die
        // Wörter vorab auf Ganzzahlen abgebildet (Ganzzahl- statt
        // String-Vergleich pro Zelle).
        var wordIDs: [String: Int] = [:]
        func id(for norm: String) -> Int {
            if let existing = wordIDs[norm] { return existing }
            wordIDs[norm] = wordIDs.count
            return wordIDs.count - 1
        }
        let rawIDs = rawTokens.map { id(for: $0.norm) }
        let cleanIDs = cleanTokens.map { id(for: $0.norm) }
        var anchors: [(raw: Int, clean: Int)] = []
        lcsAnchors(rawIDs, cleanIDs, rawRange: 0..<n, cleanRange: 0..<m, into: &anchors)

        // Je Ausgabe-Wort: Deckungsbereich in Roh-Wort-Indizes (für die spätere
        // Rücksetzung) und ob es zu einer unzulässigen Änderung gehört.
        var tainted = [Bool](repeating: false, count: m)
        var rawLo = [Int](repeating: 0, count: m)
        var rawHi = [Int](repeating: 0, count: m)
        var corrections = 0
        // Unzulässig weggelassene Wörter, einzeln für die Nachbewertung unten.
        // Neben dem Wort selbst bleiben die Grenzen der ganzen Löschungslücke
        // erhalten: Eine Satzgrenze kann vor einem ebenfalls gelöschten Füllwort
        // stehen und gehört trotzdem zur Einordnung der folgenden Verneinung.
        var droppedMeaning: [(
            rawStart: Int, rawEnd: Int, gapStart: Int, gapEnd: Int, cleanIndex: Int
        )] = []
        // Nur eindeutige Sprechpausen löschen. „um“, „also“, „halt“ und
        // „quasi“ können Bedeutung tragen; Sprache=auto erlaubt keine sichere
        // Zuordnung. Eine unmittelbare Wiederholung muss daneben wortgleich
        // erhalten bleiben und darf keine Satzteilgrenze überschreiten.
        let hesitationWords: Set<String> = ["äh", "ähm", "ähh", "öh", "öhm", "uh", "uhm", "erm"]
        func mayDelete(_ index: Int, cleanIndex: Int) -> Bool {
            let word = rawTokens[index].norm
            if hesitationWords.contains(word) { return true }
            guard !word.contains(where: { $0.isNumber }) else { return false }
            for (rawNeighbor, cleanNeighbor) in [(index - 1, cleanIndex - 1),
                                                 (index + 1, cleanIndex)] {
                guard rawNeighbor >= 0, rawNeighbor < n,
                      cleanNeighbor >= 0, cleanNeighbor < m,
                      rawTokens[rawNeighbor].norm == word,
                      cleanTokens[cleanNeighbor].norm == word else { continue }
                let left = min(index, rawNeighbor), right = max(index, rawNeighbor)
                let between = rawTokens[left].range.upperBound..<rawTokens[right].range.lowerBound
                let separator = raw[between]
                if !separator.isEmpty, separator.allSatisfy({ $0.isWhitespace }) { return true }
            }
            return false
        }
        // Bewertet die Lücke rawTokens[rs..<re] / cleanTokens[cs..<ce] vor einem Anker.
        func classifyGap(_ rs: Int, _ re: Int, _ cs: Int, _ ce: Int) {
            guard ce > cs else {
                // Jede unbelegte Löschung zurücksetzen, nicht nur Verneinungen:
                // auch Beträge, Termine und mehrdeutige Wörter bleiben erhalten.
                guard rs < re else { return }
                for rawIndex in rs..<re where !mayDelete(rawIndex, cleanIndex: cs) {
                    droppedMeaning.append((rawIndex, rawIndex + 1, rs, re, cs))
                }
                return
            }
            let allowed = rs < re && isAllowedReplacement(
                rawSpan: rawTokens[rs..<re].map(\.norm),
                cleanedSpan: cleanTokens[cs..<ce].map(\.norm),
                dictionary: dictionary
            )
            if allowed { corrections += max(re - rs, ce - cs) }
            for c in cs..<ce {
                tainted[c] = !allowed  // rs == re wäre eine reine Einfügung: verboten
                rawLo[c] = rs
                rawHi[c] = re
            }
        }
        // Anker vorwärts ablaufen: Alles zwischen zwei Ankern ist eine Lücke.
        var gapRawStart = 0, gapCleanStart = 0
        for anchor in anchors {
            classifyGap(gapRawStart, anchor.raw, gapCleanStart, anchor.clean)
            rawLo[anchor.clean] = anchor.raw
            rawHi[anchor.clean] = anchor.raw + 1
            gapRawStart = anchor.raw + 1
            gapCleanStart = anchor.clean + 1
        }
        classifyGap(gapRawStart, n, gapCleanStart, m)

        // Steht im ROHTEXT direkt vor dem Wort mit diesem Index eine
        // Satzteil-Grenze? (`index == n` heißt „hinter dem letzten Wort“ — dort
        // folgt nichts mehr, also auch keine Grenze.)
        func rawClauseBoundary(before index: Int) -> Bool {
            guard index > 0, index < n else { return false }
            return isClauseBoundary(raw[rawTokens[index - 1].range.upperBound
                                          ..< rawTokens[index].range.lowerBound])
        }
        /// Liegt an irgendeiner Wortkante in diesem Teil der Löschungslücke
        /// eine Satzteil-Grenze? Beide Enden sind inklusive; `before n` ist
        /// absichtlich immer falsch und macht auch eine Lücke am Textende sicher.
        func rawClauseBoundary(from lower: Int, through upper: Int) -> Bool {
            guard lower <= upper else { return false }
            return (lower...upper).contains(where: rawClauseBoundary(before:))
        }
        // Unzulässig weggelassene Wörter nachtragen. Eine reine Löschung hat kein
        // eigenes Ausgabe-Wort, an dem die Rücksetzung hängen könnte — deshalb
        // erbt sie normalerweise das Ausgabe-Wort direkt VOR der Lücke (steht die
        // Lücke ganz am Anfang, das erste Wort dahinter; die Ausnahme an der
        // Satzteil-Grenze steht in der Schleife). Genau dessen Satzteil ist der,
        // aus dem das Wort verschwunden ist. Sein Roh-Deckungsbereich wächst
        // um die gelöschten Roh-Wörter, damit der Wiederaufbau sie wieder einsetzt.
        // Erst hier und nicht in `classifyGap`, weil der Ankerlauf oben rawLo/rawHi
        // der Anker-Wörter nach dem Lückenaufruf noch überschreibt.
        // Mehrfach dasselbe Wort zu markieren ist harmlos: `tainted` ist ein
        // Ja/Nein-Merker, und der Wiederaufbau setzt jeden Satzteil genau einmal
        // zurück (`nextRaw` verhindert doppelt eingefügte Roh-Wörter).
        for drop in droppedMeaning {
            var neighbor = max(drop.cleanIndex - 1, 0)  // m > 0 ist oben sichergestellt
            // Zu welchem Satzteil das verschluckte Wort gehörte, steht im
            // Rohtext: Eröffnete es dort einen neuen Satzteil — direkt davor ein
            // Punkt/Komma, direkt dahinter keiner —, gehört es zum FOLGENDEN
            // Ausgabe-Wort. Ohne diese Unterscheidung wurde bei
            // „erster satz. nicht machen wir das“ -> „Erster Satz. Machen wir
            // das.“ der unveränderte erste Satz zurückgesetzt, und die
            // Verneinung hing als Rest an dessen Ende. Umgekehrt schließt
            // „das geht so nicht, wir machen …“ den ERSTEN Satzteil ab — dort
            // bleibt es beim Wort davor.
            let boundaryBeforeWord = rawClauseBoundary(
                from: drop.gapStart, through: drop.rawStart
            )
            let boundaryAfterWord = rawClauseBoundary(
                from: drop.rawEnd, through: drop.gapEnd
            )
            if drop.cleanIndex < m, boundaryBeforeWord, !boundaryAfterWord {
                neighbor = drop.cleanIndex
            }
            tainted[neighbor] = true
            rawLo[neighbor] = min(rawLo[neighbor], drop.rawStart)
            rawHi[neighbor] = max(rawHi[neighbor], drop.rawEnd)
        }

        // Backstop gegen schleichendes Umschreiben: viele erlaubte Mini-Korrekturen.
        let budget = max(4, Int((0.25 * Double(n)).rounded(.up)))
        if corrections > budget {
            return .rejected(reason: L10n.text("core.cleanup.words_changed"))
        }
        if !tainted.contains(true) {
            return .accepted(text: cleaned, revertedClauses: 0)
        }

        // Satzteile bilden: Jede Interpunktion zwischen zwei Ausgabe-Wörtern
        // eröffnet einen neuen Satzteil.
        var clauseOf = [Int](repeating: 0, count: m)
        var clause = 0
        for j in 1..<m {
            let gap = cleaned[cleanTokens[j - 1].range.upperBound..<cleanTokens[j].range.lowerBound]
            if isClauseBoundary(gap) { clause += 1 }
            clauseOf[j] = clause
        }
        let clauseCount = clause + 1
        var clauseTainted = [Bool](repeating: false, count: clauseCount)
        var clauseRawLo = [Int](repeating: Int.max, count: clauseCount)
        var clauseRawHi = [Int](repeating: 0, count: clauseCount)
        var clauseFirst = [Int](repeating: Int.max, count: clauseCount)
        var clauseLast = [Int](repeating: 0, count: clauseCount)
        for j in 0..<m {
            let k = clauseOf[j]
            if tainted[j] { clauseTainted[k] = true }
            clauseRawLo[k] = min(clauseRawLo[k], rawLo[j])
            clauseRawHi[k] = max(clauseRawHi[k], rawHi[j])
            clauseFirst[k] = min(clauseFirst[k], j)
            clauseLast[k] = max(clauseLast[k], j)
        }
        let revertedCount = clauseTainted.filter { $0 }.count
        // Muss mehr als die Hälfte zurückgesetzt werden, ist die Ausgabe insgesamt
        // nicht vertrauenswürdig — dann ist der komplette Rohtext die ehrlichere Wahl.
        if revertedCount * 2 > clauseCount {
            return .rejected(reason: L10n.text("core.cleanup.words_changed"))
        }

        // Wiederaufbau: unauffällige Satzteile wörtlich aus der Ausgabe übernehmen
        // (inklusive ihrer Interpunktion), zurückgesetzte durch die Roh-Wörter
        // ersetzen. `nextRaw` verhindert, dass sich überlappende Deckungsbereiche
        // benachbarter Satzteile Roh-Wörter doppelt einfügen.
        var result = ""
        var cursor = cleaned.startIndex
        var nextRaw = 0
        for k in 0..<clauseCount {
            let firstToken = cleanTokens[clauseFirst[k]]
            let lastToken = cleanTokens[clauseLast[k]]
            if clauseTainted[k] {
                result += cleaned[cursor..<firstToken.range.lowerBound]
                let lo = min(max(clauseRawLo[k], nextRaw), n)
                let hi = min(max(clauseRawHi[k], lo), n)
                if lo < hi {
                    // Original-Substring statt mit Leerzeichen zusammengesetzter
                    // Einzelwörter: So überleben Binde-/Schrägstriche, Apostrophe
                    // und die Roh-Interpunktion ("CI/CD-Workflow") die Rücksetzung.
                    result += raw[rawTokens[lo].range.lowerBound..<rawTokens[hi - 1].range.upperBound]
                }
                nextRaw = hi
            } else {
                result += cleaned[cursor..<lastToken.range.upperBound]
                nextRaw = max(nextRaw, clauseRawHi[k])
            }
            cursor = lastToken.range.upperBound
        }
        result += cleaned[cursor...]  // Interpunktion nach dem letzten Wort
        return .accepted(text: result, revertedClauses: revertedCount)
    }

    /// Ein Wort des Originaltexts samt Fundstelle und normalisierter Form.
    ///
    /// Die Original-Schreibweise steht bewusst NICHT hier: Der Wiederaufbau
    /// schneidet zurückgesetzte Satzteile am Stück über `range` aus dem Rohtext
    /// aus. Ein zusätzlicher `Substring` je Wort wäre nur Ballast — und gerade
    /// lange Diktate sollen wenig Speicher kosten.
    private struct Token {
        /// Vergleichsform: Unicode-normalisiert und kleingeschrieben — Satzzeichen
        /// und Groß-/Kleinschreibung sind für die Treueprüfung egal.
        let norm: String
        /// Fundstelle im Originalstring (für den Klausel-Wiederaufbau).
        let range: Range<String.Index>
    }

    /// Ein Marker darf kein Inhaltswort oder Unicode-Symbol überqueren. Hier
    /// gelten nur Schreibfall/Satzzeichen, eindeutige Pausen und unmittelbare
    /// Wiederholungen als variabel. Der unveränderte Gesamtvergleich folgt
    /// zusätzlich; kleine Wortersetzungen sind für diesen Lagebeleg zu unsicher.
    static func preservesFormattingPosition(raw: String, cleaned: String) -> Bool {
        let original = tokens(in: raw), output = tokens(in: cleaned)
        let pauses: Set<String> = ["äh", "ähm", "ähh", "öh", "öhm", "uh", "uhm", "erm"]
        func norm(_ token: Token) -> String { token.norm == "contractednot" ? "not" : token.norm }
        var index = 0
        for (rawIndex, token) in original.enumerated() {
            if index < output.count, norm(token) == norm(output[index]) { index += 1; continue }
            if pauses.contains(token.norm) { continue }
            let repeated = [(rawIndex - 1, index - 1), (rawIndex + 1, index)].contains { neighbor, target in
                guard !token.norm.contains(where: \.isNumber),
                      original.indices.contains(neighbor), output.indices.contains(target),
                      norm(original[neighbor]) == norm(token), norm(output[target]) == norm(token) else { return false }
                let left = min(rawIndex, neighbor), right = max(rawIndex, neighbor)
                let gap = raw[original[left].range.upperBound..<original[right].range.lowerBound]
                return !gap.isEmpty && gap.allSatisfy(\.isWhitespace)
            }
            if !repeated { return false }
        }
        func symbols(_ text: String) -> String {
            String(text.unicodeScalars.filter { CharacterSet.symbols.contains($0) })
        }
        return index == output.count && symbols(raw) == symbols(cleaned)
    }

    /// Zerlegt Text Unicode-sicher in Wörter (Buchstaben-/Ziffernfolgen).
    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var idx = text.startIndex
        while true {
            let isWordChar = idx < text.endIndex && (text[idx].isLetter || text[idx].isNumber)
            if isWordChar, start == nil { start = idx }
            if !isWordChar, let s = start {
                let piece = text[s..<idx]
                var normalized = String(piece)
                    .precomposedStringWithCanonicalMapping.lowercased()
                // Apostrophe gehören sonst nicht zum Token. Bekannte englische
                // n't-Formen werden deshalb in ihren bejahenden Stamm plus GENAU
                // einen Verneinungsschlüssel zerlegt (`didn't` -> `did` + `not`).
                // Gerade und typografische Apostrophe werden gleich behandelt.
                if normalized == "t", s > text.startIndex {
                    let apostropheIndex = text.index(before: s)
                    let apostrophe = text[apostropheIndex]
                    if (apostrophe == "'" || apostrophe == "’"),
                       let previous = result.last,
                       previous.range.upperBound == apostropheIndex,
                       let affirmative = negativeContractionStems[previous.norm] {
                        result[result.count - 1] = Token(
                            norm: affirmative, range: previous.range
                        )
                        normalized = "contractednot"
                    }
                }
                result.append(Token(
                    norm: normalized,
                    range: s..<idx
                ))
                start = nil
            }
            if idx == text.endIndex { break }
            idx = text.index(after: idx)
        }
        return result
    }

    /// Wortteil vor dem Apostroph -> bejahender Stamm. Nur bekannte n't-Formen
    /// werden umgeschrieben; ein beliebiges Wort mit angehängtem `'t` bekommt
    /// nicht versehentlich die Bedeutung „not“.
    private static let negativeContractionStems: [String: String] = [
        "ain": "ain", "aren": "are", "can": "can", "couldn": "could",
        "didn": "did", "doesn": "does", "don": "do", "hadn": "had",
        "hasn": "has", "haven": "have", "isn": "is", "mightn": "might",
        "mustn": "must", "needn": "need", "oughtn": "ought", "shan": "shall",
        "shouldn": "should", "wasn": "was", "weren": "were", "won": "will",
        "wouldn": "would",
    ]

    /// Sammelt die Anker-Paare (Roh-Index, Ausgabe-Index) einer längsten
    /// gemeinsamen Teilfolge nach Hirschberg: Die Roh-Seite wird halbiert, beide
    /// Hälften werden nur über LCS-LÄNGEN-Zeilen bewertet (je zwei Zeilen statt
    /// einer vollen Tabelle), und an der besten Trennstelle geht es rekursiv
    /// weiter. Zeit O(n·m) wie die klassische Tabelle, Speicher aber nur O(n+m).
    private static func lcsAnchors(_ raw: [Int], _ clean: [Int],
                                   rawRange: Range<Int>, cleanRange: Range<Int>,
                                   into anchors: inout [(raw: Int, clean: Int)]) {
        if rawRange.isEmpty || cleanRange.isEmpty { return }
        if rawRange.count == 1 {
            // Basisfall: Ein einzelnes Roh-Wort ankert am ersten gleichen Ausgabe-Wort.
            for j in cleanRange where clean[j] == raw[rawRange.lowerBound] {
                anchors.append((rawRange.lowerBound, j))
                return
            }
            return
        }
        // Obere Roh-Hälfte vorwärts, untere rückwärts bewerten; die Ausgabe wird
        // dort geteilt, wo beide Hälften zusammen die längste Teilfolge ergeben.
        let mid = (rawRange.lowerBound + rawRange.upperBound) / 2
        let upper = lcsRow(raw, clean, rawRange: rawRange.lowerBound..<mid,
                           cleanRange: cleanRange, reversed: false)
        let lower = lcsRow(raw, clean, rawRange: mid..<rawRange.upperBound,
                           cleanRange: cleanRange, reversed: true)
        var split = cleanRange.lowerBound
        var best = -1
        // Gleichstand bewusst zugunsten der SPÄTEN Trennstelle auflösen (`>=`):
        // Je weiter rechts geteilt wird, desto mehr Ausgabe-Wörter bekommt die
        // frühe Roh-Hälfte — die Anker liegen dann so früh wie möglich im
        // Rohtext. Mit `>` gewann die früheste Trennstelle, und die frühe
        // Roh-Hälfte ging leer aus: Aus „wir machen heute wir testen jetzt wir
        // machen morgen“ -> „Wir machen Sorgen.“ wurden die SPÄTEN Vorkommen
        // von „wir machen“ zu Ankern. Der lange Anfang galt dadurch als reine
        // (erlaubte) Löschung und „morgen“ -> „sorgen“ als Tippfehler — eine
        // stark gekürzte und inhaltlich veränderte Ausgabe bestand die Prüfung.
        for offset in 0...cleanRange.count where upper[offset] + lower[offset] >= best {
            best = upper[offset] + lower[offset]
            split = cleanRange.lowerBound + offset
        }
        lcsAnchors(raw, clean, rawRange: rawRange.lowerBound..<mid,
                   cleanRange: cleanRange.lowerBound..<split, into: &anchors)
        lcsAnchors(raw, clean, rawRange: mid..<rawRange.upperBound,
                   cleanRange: split..<cleanRange.upperBound, into: &anchors)
    }

    /// Letzte Zeile der LCS-Längentabelle für raw[rawRange] × clean[cleanRange],
    /// gerechnet mit zwei Zeilen. Vorwärts steht an Index k die LCS-Länge gegen
    /// das Ausgabe-PRÄFIX der Länge k, rückwärts (für die untere
    /// Hirschberg-Hälfte) die gegen das Ausgabe-SUFFIX ab Offset k.
    private static func lcsRow(_ raw: [Int], _ clean: [Int],
                               rawRange: Range<Int>, cleanRange: Range<Int>,
                               reversed: Bool) -> [Int] {
        let width = cleanRange.count
        var previous = [Int](repeating: 0, count: width + 1)
        var current = previous
        if reversed {
            for i in stride(from: rawRange.upperBound - 1, through: rawRange.lowerBound, by: -1) {
                for offset in stride(from: width - 1, through: 0, by: -1) {
                    current[offset] = raw[i] == clean[cleanRange.lowerBound + offset]
                        ? previous[offset + 1] + 1
                        : max(previous[offset], current[offset + 1])
                }
                swap(&previous, &current)
            }
        } else {
            for i in rawRange {
                for offset in 0..<width {
                    current[offset + 1] = raw[i] == clean[cleanRange.lowerBound + offset]
                        ? previous[offset] + 1
                        : max(previous[offset + 1], current[offset])
                }
                swap(&previous, &current)
            }
        }
        return previous
    }

    /// Zählt der Text zwischen zwei Wörtern als Satzteil-Grenze? Interpunktion ja;
    /// ein Bindestrich nur mit Leerraum daneben (Gedankenstrich) — "Repo-Rack"
    /// bleibt EIN Satzteil.
    private static func isClauseBoundary(_ gap: Substring) -> Bool {
        let marks: Set<Character> = [".", ":", ",", ";", "!", "?", "–", "—", "…",
                                     "\"", "„", "“", "”", "«", "»", "(", ")"]
        if gap.contains(where: { marks.contains($0) }) { return true }
        if gap.contains("-"), gap.contains(where: \.isWhitespace) { return true }
        return false
    }

    /// Normalisiert Wörterbuch-Begriffe für den Treue-Abgleich: kleingeschrieben,
    /// nur Buchstaben/Ziffern ("Stille Post" -> "stillepost", "beispiel.de" -> "beispielde") —
    /// dieselbe Form, in der auch Ausrichtungslücken zusammengefügt werden.
    static func normalizedDictionary(_ terms: [String]) -> Set<String> {
        Set(terms.map { term in
            String(term.precomposedStringWithCanonicalMapping.lowercased()
                .filter { $0.isLetter || $0.isNumber })
        }.filter { !$0.isEmpty })
    }

    /// True bei zulässigen Ersetzungen an einer Ausrichtungslücke. Bewusst
    /// begrenzt (Sicherheit vor Rettung) — Bedeutungsänderungen, die anders
    /// klingen ("verbinden" -> "verwenden"), bleiben unzulässig:
    ///   1. zusammengefügt gleich   -> reine Wort-Trennung/-Fusion ("dauer haft"->"dauerhaft")
    ///   2. Wörterbuch-Fachbegriff  -> erlaubt, wenn er ähnlich klingt ("mini macs"->"minimax")
    ///   3. Editierabstand <= 1     -> ein Tippfehler/Verhörer ("olama"->"ollama")
    ///   4. Präfix + Endung <= 2    -> kurze Flexion ("ein"->"einen", "...ung"->"...ungen")
    ///   5. gleicher Lautcode       -> klingt identisch (Kölner Phonetik, "rack"->"rag")
    ///
    /// Über allem (außer Regel 1) steht die Sperrliste `meaningCriticalWords`:
    /// Wörter, deren Austausch die Aussage umdreht, dürfen von diesen Toleranzen
    /// nicht angefasst werden ("kein" -> "ein" ist nur ein Buchstabe).
    private static func isAllowedReplacement(
        rawSpan: [String], cleanedSpan: [String], dictionary: Set<String>
    ) -> Bool {
        let joinedRaw = rawSpan.joined()
        let joinedCleaned = cleanedSpan.joined()
        let a = Array(joinedRaw)
        let b = Array(joinedCleaned)
        if a == b { return true }  // reine Wort-Trennung/-Fusion: Buchstaben identisch
        // `contractednot` ist die interne Form des Apostroph-t. Für die
        // Äquivalenzprüfung entspricht sie dem ausgeschriebenen `not`:
        // `did` + `contractednot` und `did` + `not` sind derselbe Inhalt.
        let expandedRaw = rawSpan.map { $0 == "contractednot" ? "not" : $0 }.joined()
        let expandedCleaned = cleanedSpan.map { $0 == "contractednot" ? "not" : $0 }.joined()
        if expandedRaw == expandedCleaned { return true }
        // Sperrliste ZUERST (nur die buchstabengleiche Trennung/Fusion oben darf
        // vorbei, die ändert nichts an der Aussage): Verschwindet ein
        // sinnumkehrendes Wort auf einer Seite oder taucht es neu auf, ist das
        // keine Rettung mehr, sondern eine andere Aussage -> zurück auf den Rohtext.
        if meaningKeys(rawSpan) != meaningKeys(cleanedSpan) { return false }
        // Wörterbuch: Ein konfigurierter Fachbegriff darf einen ähnlich klingenden
        // Verhörer ersetzen — Ähnlichkeit über den Lautcode (Abstand <= 1), damit
        // nicht jedes beliebige Wort zum Fachbegriff "korrigiert" werden darf.
        if dictionary.contains(joinedCleaned) {
            let rawCode = Array(TranscriptPolish.colognePhonetics(joinedRaw))
            let cleanedCode = Array(TranscriptPolish.colognePhonetics(joinedCleaned))
            if editDistance(rawCode, cleanedCode) <= 1 { return true }
        }
        // Tokens mit Ziffern sind fast immer technische Kennungen (Modell-/Versions-
        // namen wie "426b", "id3", "3.59b"): dort ist schon ein Zeichen Unterschied
        // bedeutungstragend. Keine Tippfehler-/Flexionstoleranz — nur exakt gleich.
        if a.contains(where: \.isNumber) || b.contains(where: \.isNumber) { return false }
        if editDistance(a, b) <= 1 { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if long.count - short.count <= 2, long.starts(with: short) { return true }
        // Gleich klingende Wörter sind Hör-/Schreibvarianten desselben Diktats
        // ("Rack" -> "RAG"). Erst ab 3 Buchstaben je Seite — sehr kurze Wörter
        // ("er"/"ihr") teilen sich sonst zu leicht einen Lautcode.
        if a.count >= 3, b.count >= 3 {
            let rawCode = TranscriptPolish.colognePhonetics(joinedRaw)
            if !rawCode.isEmpty, rawCode == TranscriptPolish.colognePhonetics(joinedCleaned) {
                return true
            }
        }
        return false
    }

    /// Sperrliste: Wörter, deren Austausch oder Wegfall den Sinn eines Diktats umdreht.
    ///
    /// Warum es sie braucht: Die Toleranzen oben sind als Verhörer-Rettung gedacht
    /// und messen nur ÄHNLICHKEIT, nicht Bedeutung. Genau bei den kurzen
    /// Funktionswörtern fällt beides auseinander — "kein" und "ein" trennt ein
    /// einziger Buchstabe, die Aussage aber das Gegenteil. Ein Diktat, in dem aus
    /// "ich habe kein Problem" ein "ich habe ein Problem" wird, ist schlimmer als
    /// ein ungeputzter Satz.
    ///
    /// Aufnahmekriterium (beides muss zutreffen, sonst bläht die Liste nur auf):
    ///  1. Das Wort verneint die Aussage oder begrenzt ihre Reichweite.
    ///  2. Es liegt unter den Toleranzen oben tatsächlich in Reichweite eines
    ///     gebräuchlichen anderen Wortes — sonst kann gar nichts passieren.
    ///     Belege: kein/ein, keine/eine, keinen/einen … (Editierabstand 1),
    ///     nicht/nichts (Flexionsregel), nie/wie/sie/die, nein/ein/neun,
    ///     nur/nun, immer/nimmer, weder/jeder, nirgendwo/irgendwo (Abstand 1),
    ///     ohne/ahne (gleicher Kölner Lautcode "06").
    ///
    /// Die Liste schützt Ersetzungen. Reine Löschungen schützt `reconcile`
    /// unabhängig von dieser Liste über eine enge Positivliste für Sprechpausen
    /// und unmittelbar wortgleich erhaltene Wiederholungen.
    ///
    /// Schlüssel: die normalisierte Wortform (kleingeschrieben, nur Buchstaben) —
    /// genau die Form, in der die Ausrichtung Wörter vergleicht.
    /// Wert: der gemeinsame Bedeutungsschlüssel der Wortfamilie. Alle "kein"-Formen
    /// teilen ihn, damit die reine BEUGUNG erlaubt bleibt ("kein" -> "keinen"),
    /// während der Wegfall der Verneinung ("kein" -> "ein") gesperrt ist.
    ///
    /// Bewusst NICHT auf der Liste stehen die harmlosen Gegenstücke ("ein", "wie",
    /// "nun"): Der Vergleich unten ist seitenweise, deshalb schlägt er auch an,
    /// wenn die Verneinung nur auf EINER Seite steht. Stünde "ein" mit drauf,
    /// wäre die gewollte Flexionsrettung "ein" -> "einen" mit gesperrt.
    ///
    /// Englisch steht mit auf der Liste, weil `whisper.language` standardmäßig
    /// `auto` ist und `en` ausdrücklich unterstützt wird: Ohne die englischen
    /// Einträge galt "I did not approve this" -> "I did approve this." als
    /// gewöhnliche Füllwort-Löschung. Bekannte Kurzformen normalisiert `tokens`
    /// zu bejahendem Stamm plus `contractednot`; dadurch zählt jedes n't genau
    /// einmal. Weitere Diktatsprachen sind noch nicht abgedeckt; der offene Punkt
    /// steht im Backlog.
    private static let meaningCriticalWords: [String: String] = [
        // Verneinung
        "kein": "kein", "keine": "kein", "keinen": "kein", "keinem": "kein",
        "keiner": "kein", "keines": "kein", "keins": "kein", "keinerlei": "kein",
        "nicht": "nicht",
        "nichts": "nichts",
        "nie": "nie", "niemals": "nie", "nimmer": "nie",
        "niemand": "niemand", "niemandem": "niemand", "niemanden": "niemand",
        "niemandes": "niemand",
        "nirgends": "nirgend", "nirgendwo": "nirgend", "nirgendwohin": "nirgend",
        "nein": "nein",
        "ohne": "ohne",
        "weder": "weder",
        // Reichweite und Menge: kehren die Aussage zwar nicht um, behaupten aber
        // etwas anderes ("nur zwei" ist keine Aussage über alle, "nicht mehr" ist
        // kein "nicht sehr").
        "nur": "nur",
        "mehr": "mehr",
        "immer": "immer",
        // Englisch — dieselben zwei Kriterien. "not"/"note", "no"/"know",
        // "only"/"once" liegen unter den Toleranzen in Reichweite voneinander.
        "not": "not", "cannot": "not", "contractednot": "not",
        "no": "no", "none": "no",
        "never": "never",
        "nothing": "nothing",
        "nobody": "nobody",
        "nowhere": "nowhere",
        "neither": "neither",
        "nor": "nor",
        "without": "without",
        "only": "only",
    ]

    /// Die Bedeutungsschlüssel der Sperrliste in dieser Wortfolge — in Reihenfolge,
    /// damit auch ein Vertauschen auffällt. Wörter außerhalb der Liste zählen nicht.
    private static func meaningKeys(_ span: [String]) -> [String] {
        span.compactMap { meaningCriticalWords[$0] }
    }

    /// Levenshtein-Editierabstand auf Zeichenebene (zwei Zeilen, O(min·max) Zeit).
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
