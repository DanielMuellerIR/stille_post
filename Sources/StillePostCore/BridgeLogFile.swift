import Foundation

/// Schreibt die Protokollzeilen der Netzwerk-Brücke in eine Datei neben
/// `config.json`.
///
/// Warum es das gibt: Die Brücke meldete ihre Zeilen bisher nur nach stderr. Bei
/// der aus dem Finder gestarteten App landet stderr nirgends — ein „vom iPhone
/// kommt nichts an“ war damit von außen überhaupt nicht nachvollziehbar, und die
/// Fehlersuche musste die App durch die CLI ersetzen. Mit der Datei gibt es einen
/// Ort zum Nachsehen.
///
/// Was NICHT hineingeschrieben wird: Diktattext und Token. Die Zeilen der Brücke
/// enthalten beides ohnehin nicht — sie nennen Methode, Pfad, Status, Größe,
/// Dauer und die Adresse der Gegenstelle.
public final class BridgeLogFile: @unchecked Sendable {

    /// Ab dieser Größe wird die Datei einmal weggeräumt. Eine Generation reicht:
    /// Das Protokoll dient der Fehlersuche im Heimnetz, nicht der Archivierung.
    public static let maxBytes = 1_048_576

    public static var defaultURL: URL {
        Config.appSupportDir.appendingPathComponent("bridge.log")
    }

    private let url: URL
    private let maxBytes: Int
    /// Alle Schreibzugriffe laufen über diese Queue: Die Brücke protokolliert aus
    /// ihrer eigenen Queue heraus, die App zusätzlich beim Start.
    private let queue = DispatchQueue(label: "de.stillepost.bridge.log")

    public init(url: URL = BridgeLogFile.defaultURL, maxBytes: Int = BridgeLogFile.maxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// Hängt eine Zeile mit Zeitstempel an. Fehler werden bewusst verschluckt:
    /// Ein nicht schreibbares Protokoll darf das Diktat nicht stören.
    public func append(_ message: String) {
        queue.async { [url, maxBytes] in
            let line = "\(BridgeLogFile.timestamp()) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let manager = FileManager.default

            // Vor dem Schreiben aufräumen, damit die Datei nicht unbegrenzt wächst.
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
               size + data.count > maxBytes {
                let previous = url.appendingPathExtension("1")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
            // Noch keine Datei: Ordner sicherstellen und neu anlegen.
            try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Wartet, bis alle bisherigen Zeilen geschrieben sind — für Tests und für
    /// den geordneten Abschluss.
    public func flush() {
        queue.sync {}
    }

    /// Zeitstempel nach ISO 8601 in Ortszeit. Ohne ihn wäre eine Protokolldatei
    /// für die Fehlersuche wertlos: Man will wissen, ob die Zeile zum eigenen
    /// Versuch von gerade eben gehört.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime,
                                   .withDashSeparatorInDate, .withSpaceBetweenDateAndTime]
        return formatter.string(from: date)
    }
}
