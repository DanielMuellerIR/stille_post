import Foundation

/// Deterministische Textstufen rund um die LLM-Bereinigung — ganz ohne Modell:
///
///  1. `flattenLineBreaks` (VOR dem LLM): Whisper streut Zeilenumbrüche als reine
///     Transkriptions-Artefakte in den Text, teils sogar mitten ins Wort
///     ("Identitä\ntsproblem"). Die entfernen wir regelbasiert.
///  2. `repairPunctuation` (NACH dem LLM, nur auf Fallback-/Rohtext): korrigiert
///     die sicher entscheidbaren Satzzeichen-/Großschreibungsfälle, damit auch ein
///     Diktat ohne (erfolgreiche) LLM-Bereinigung lesbar ankommt.
///  3. `colognePhonetics` (Kölner Phonetik): "Klingt das gleich?" deterministisch
///     beantworten — Grundlage der phonetischen Toleranz der Worttreue-Prüfung
///     ("Rack" ≈ "RAG").
///
/// Empirische Grundlage für Regel 1 (echter Verlaufskorpus, 238 Diktate):
/// Umbrüche ZWISCHEN Wörtern tragen immer ein Leerzeichen nach dem `\n`;
/// steht ein Kleinbuchstabe direkt hinter dem Umbruch, war es ausnahmslos ein
/// zerrissenes Wort. Genau darauf stützt sich die Join-Heuristik.
public enum TranscriptPolish {

    // MARK: - Vorstufe: Zeilenumbruch-Artefakte

    /// Entfernt Whisper-Zeilenumbrüche: Ein purer Umbruch zwischen Buchstabe und
    /// Kleinbuchstabe fügt das zerrissene Wort wieder zusammen; jeder andere
    /// Umbruch (und mehrfacher Leerraum) wird zu genau einem Leerzeichen.
    public static func flattenLineBreaks(_ text: String) -> String {
        var result = ""
        var pendingWhitespace = ""
        for ch in text {
            if ch.isWhitespace {
                pendingWhitespace.append(ch)
                continue
            }
            if !pendingWhitespace.isEmpty {
                defer { pendingWhitespace = "" }
                // Zerrissenes Wort: NUR Umbruch (kein Leerzeichen dabei), Buchstabe
                // davor, Kleinbuchstabe danach -> ohne Leerzeichen zusammenfügen.
                let pureNewline = pendingWhitespace.allSatisfy(\.isNewline)
                if pureNewline, pendingWhitespace.contains(where: \.isNewline),
                   let prev = result.last, prev.isLetter, ch.isLetter, ch.isLowercase {
                    // nichts einfügen — Wortteile direkt verbinden
                } else if !result.isEmpty {
                    result.append(" ")
                }
                // Führender Leerraum wird verworfen (result noch leer).
            }
            result.append(ch)
        }
        return result
    }

    // MARK: - Nachstufe: sichere Satzzeichen-/Großschreibungs-Reparatur

    /// Repariert regelbasiert nur die Fälle, die ohne Sprachverständnis sicher
    /// entscheidbar sind (bewusst konservativ — Deutsch schreibt Substantive groß,
    /// deshalb wird NIE etwas kleingeschrieben):
    ///  - "wort. kleinwort" -> "wort, kleinwort": Ein Punkt vor einem kleinen
    ///    Wortanfang ist ein Segmentgrenzen-Artefakt, kein Satzende. Geschützt
    ///    bleiben Abkürzungen ("z. B.", Wort vor dem Punkt kürzer als 3 Buchstaben),
    ///    Zahlen/Datumsangaben ("27.07.") und Auslassungspunkte ("...").
    ///  - Nach "!" und "?" wird der nächste Buchstabe großgeschrieben.
    ///  - Der erste Buchstabe des Texts wird großgeschrieben.
    public static func repairPunctuation(_ text: String) -> String {
        var chars = Array(collapseDoubledPunctuation(text))

        // Durchgang 1: Punkt mitten im Satz (". klein") wird zum Komma.
        var wordBeforeDot: [Character] = []  // das Wort unmittelbar vor der aktuellen Position
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch.isLetter || ch.isNumber {
                wordBeforeDot.append(ch)
                index += 1
                continue
            }
            if ch == "." {
                let isSingleDot = (index == 0 || chars[index - 1] != ".")
                    && (index + 1 >= chars.count || chars[index + 1] != ".")
                // Nächstes Nicht-Leerzeichen suchen — es muss NACH Leerraum kommen,
                // sonst ist der Punkt Teil eines Tokens ("dm0.de", "1.5").
                var next = index + 1
                var sawWhitespace = false
                while next < chars.count, chars[next].isWhitespace {
                    sawWhitespace = true
                    next += 1
                }
                if isSingleDot, sawWhitespace, next < chars.count,
                   chars[next].isLetter, chars[next].isLowercase,
                   wordBeforeDot.count >= 3, wordBeforeDot.allSatisfy(\.isLetter) {
                    chars[index] = ","
                }
            }
            wordBeforeDot = []
            index += 1
        }

        // Durchgang 2: Großschreibung nach echten Satzenden ("!" und "?") sowie am
        // Textanfang. Punkte sind hier bewusst außen vor: Nach Durchgang 1 folgt
        // auf einen verbliebenen Punkt entweder schon ein Großbuchstabe oder eine
        // geschützte Abkürzung ("z. B. und ..."), die klein bleiben muss.
        var lastMark: Character?
        var isFirstLetter = true
        for i in chars.indices {
            let ch = chars[i]
            if ch.isWhitespace { continue }
            if ch.isLetter {
                if isFirstLetter || lastMark == "!" || lastMark == "?" {
                    let upper = String(ch).uppercased()
                    if upper.count == 1, let first = upper.first {
                        chars[i] = first
                    }
                }
                isFirstLetter = false
            }
            lastMark = ch
        }
        return String(chars)
    }

    /// Fasst gedoppelte Trennzeichen zusammen ("Wort, , dass" -> "Wort, dass").
    /// Solche Doppel entstehen, wenn die Worttreue-Prüfung einen Satzteil auf leer
    /// zurücksetzt und seine Rand-Interpunktion stehen bleibt. Ein Komma/Semikolon
    /// direkt vor weiterer Interpunktion trägt nie Bedeutung — es fliegt raus.
    private static func collapseDoubledPunctuation(_ text: String) -> String {
        var current = text
        while true {
            let next = current.replacing(#/[,;][ \t]*(?=[,;.!?])/#, with: "")
            if next == current { return next }
            current = next
        }
    }

    // MARK: - Kölner Phonetik

    /// Kölner Phonetik: bildet ein Wort auf einen Lautcode ab, sodass gleich
    /// klingende deutsche Wörter denselben Code bekommen ("Rack" und "RAG" -> "74",
    /// "Meier" und "Mayr" -> "67"). Nicht-Buchstaben werden ignoriert; Umlaute
    /// zählen wie ihre Grundvokale.
    public static func colognePhonetics(_ word: String) -> String {
        // Auf A–Z reduzieren ("ß".uppercased() == "SS" passt dabei automatisch).
        var letters: [Character] = []
        for ch in word.uppercased() {
            switch ch {
            case "Ä": letters.append("A")
            case "Ö": letters.append("O")
            case "Ü": letters.append("U")
            case "A"..."Z": letters.append(ch)
            default: break
            }
        }

        // Buchstabe -> Ziffern, teils abhängig vom Vorgänger/Nachfolger.
        var codes: [Character] = []
        for (i, ch) in letters.enumerated() {
            let prev = i > 0 ? letters[i - 1] : nil
            let next = i + 1 < letters.count ? letters[i + 1] : nil
            let code: String
            switch ch {
            case "A", "E", "I", "J", "O", "U", "Y": code = "0"
            case "H": code = ""  // stumm
            case "B": code = "1"
            case "P": code = next == "H" ? "3" : "1"
            case "D", "T": code = (next == "C" || next == "S" || next == "Z") ? "8" : "2"
            case "F", "V", "W": code = "3"
            case "G", "K", "Q": code = "4"
            case "C":
                if prev == "S" || prev == "Z" {
                    code = "8"
                } else if i == 0 {
                    code = "AHKLOQRUX".contains(next.map(String.init) ?? " ") ? "4" : "8"
                } else {
                    code = "AHKOQUX".contains(next.map(String.init) ?? " ") ? "4" : "8"
                }
            case "X": code = (prev == "C" || prev == "K" || prev == "Q") ? "8" : "48"
            case "L": code = "5"
            case "M", "N": code = "6"
            case "R": code = "7"
            case "S", "Z": code = "8"
            default: code = ""
            }
            codes.append(contentsOf: code)
        }

        // Regelwerk: erst benachbarte Doppel-Codes zusammenfassen, dann alle "0"
        // außer an erster Stelle entfernen.
        var collapsed: [Character] = []
        for c in codes where c != collapsed.last {
            collapsed.append(c)
        }
        var result = ""
        for (i, c) in collapsed.enumerated() where c != "0" || i == 0 {
            result.append(c)
        }
        return result
    }
}
