import Foundation

/// Kürzt fremden Text, bevor er in Verlauf, Protokoll oder Oberfläche gerät.
///
/// Gemeint ist Text, den ein Gegenüber bestimmt: die Fehlerantwort eines
/// LLM-Dienstes, das `error`-Feld eines Stream-Frames, die Antwort des
/// whisper-servers. Solche Beschreibungen sammelt die Bereinigung als
/// `fallbackReason` ein, und von dort landen sie dauerhaft in `history.json` und
/// im Verlaufsfenster. Ohne Grenze schreibt ein einziges kaputtes Gegenüber —
/// eine HTML-Fehlerseite eines Proxys etwa — seine gesamte Ausgabe in den
/// Verlauf.
///
/// Steht bewusst an EINER Stelle, aus demselben Grund wie `ByteSize`: Die Zahl
/// stand vorher zweimal unabhängig im Code (in `CleanupService` und in
/// `WhisperClient`), obwohl beide Texte über denselben Weg im Verlauf landen.
/// Zwei Zahlen, die dasselbe meinen, laufen früher oder später auseinander.
public enum DiagnosticText {

    /// So viele Zeichen fremden Texts übernehmen wir höchstens.
    ///
    /// 300 Zeichen sind reichlich für die aussagekräftige erste Zeile einer
    /// Fehlerantwort und kurz genug, dass eine Verlaufszeile lesbar bleibt.
    public static let maxForeignCharacters = 300

    /// Kürzt fremden Text auf das Maß oben.
    public static func shortened(_ text: String) -> String {
        String(text.prefix(maxForeignCharacters))
    }
}
