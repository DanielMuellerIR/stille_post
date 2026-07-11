import Foundation

/// Verlauf aller Diktate: Text ansehen/kopieren, fehlgeschlagene erneut
/// transkribieren, alles löschen.
///
/// Speicher-Prinzip (Datensparsamkeit):
///  - Der TEXT jedes Diktats wird im Verlauf behalten (bis "Alle löschen").
///  - Das AUDIO wird sofort nach ERFOLGREICHER Transkription gelöscht.
///  - Nur bei FEHLGESCHLAGENER Transkription bleibt die Audio-Datei liegen, damit
///    "Erneut transkribieren" möglich ist. Klappt der neue Versuch, wird sie dann
///    ebenfalls gelöscht.
public final class HistoryStore {

    /// Ein Eintrag im Verlauf.
    public struct Entry: Codable, Identifiable, Equatable {
        public var id: UUID
        /// Zeitpunkt des Diktats (ISO-8601 beim Anzeigen formatiert).
        public var date: Date
        /// Roher Whisper-Text (vor der Bereinigung). Bei Fehlschlag leer.
        public var rawText: String
        /// Bereinigter (= eingefügter) Text. Bei Fehlschlag leer.
        public var cleanText: String
        /// "ok" oder "failed".
        public var status: String
        /// Fehlerbeschreibung bei status == "failed".
        public var errorMessage: String?
        /// Dateiname der zurückbehaltenen Aufnahme (nur bei Fehlschlag, sonst nil).
        /// Bewusst nur der Name, kein absoluter Pfad — der Basis-Ordner kann sich ändern.
        public var audioFileName: String?
        /// Dauer der Aufnahme in Sekunden (fürs Anzeigen).
        public var durationSec: Double
        /// Wurde bei der Bereinigung auf den Rohtext zurückgefallen? (Diagnose)
        public var cleanupFellBack: Bool?
        /// Welcher Endpoint der Kette hat bereinigt? (Diagnose: "war das der Fallback?")
        public var cleanupEndpoint: String?
        /// Wie lange hat die Bereinigung gedauert (Sekunden)? (Diagnose: "warum war
        /// das Diktat lahm — Bereinigung oder etwas anderes?")
        public var cleanupSec: Double?

        public var isFailed: Bool { status == "failed" }

        public init(id: UUID = UUID(), date: Date = Date(), rawText: String, cleanText: String,
                    status: String, errorMessage: String? = nil, audioFileName: String? = nil,
                    durationSec: Double, cleanupFellBack: Bool? = nil,
                    cleanupEndpoint: String? = nil, cleanupSec: Double? = nil) {
            self.id = id
            self.date = date
            self.rawText = rawText
            self.cleanText = cleanText
            self.status = status
            self.errorMessage = errorMessage
            self.audioFileName = audioFileName
            self.durationSec = durationSec
            self.cleanupFellBack = cleanupFellBack
            self.cleanupEndpoint = cleanupEndpoint
            self.cleanupSec = cleanupSec
        }
    }

    /// Wird nach jeder Änderung aufgerufen (fürs Aktualisieren des Verlaufsfensters).
    public var onChange: (() -> Void)?

    private let historyFile: URL
    private let audioDir: URL
    private var entries: [Entry] = []
    /// Serielle Queue: Alle Zugriffe laufen hierüber, damit App-Thread und
    /// Pipeline-Tasks sich nicht in die Quere kommen.
    private let queue = DispatchQueue(label: "stillepost.history")

    public init(baseDir: URL = Config.appSupportDir) {
        historyFile = baseDir.appendingPathComponent("history.json")
        audioDir = baseDir.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        // Datums-Format muss zum Encoder in saveLocked() passen (ISO-8601).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Entry].self, from: Data(contentsOf: historyFile))) ?? []
    }

    // MARK: - Lesen

    /// Alle Einträge, neueste zuerst.
    public func list() -> [Entry] {
        queue.sync { entries.sorted { $0.date > $1.date } }
    }

    /// Ordner, in dem fehlgeschlagene Aufnahmen liegen.
    public var recordingsDir: URL { audioDir }

    /// Absoluter Pfad zur Audio-Datei eines Eintrags (falls vorhanden).
    public func audioURL(for entry: Entry) -> URL? {
        guard let name = entry.audioFileName else { return nil }
        return audioDir.appendingPathComponent(name)
    }

    /// Erzeugt einen neuen, eindeutigen Ziel-Pfad für eine Aufnahme.
    public func newRecordingURL() -> URL {
        // ISO-Zeitstempel im Dateinamen -> alphabetisch = chronologisch sortiert.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let name = "aufnahme-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).wav"
        return audioDir.appendingPathComponent(name)
    }

    // MARK: - Schreiben

    /// Fügt einen Eintrag hinzu und speichert.
    public func append(_ entry: Entry) {
        queue.sync {
            entries.append(entry)
            saveLocked()
        }
        onChange?()
    }

    /// Ersetzt einen Eintrag (z. B. nach "Erneut transkribieren") und speichert.
    public func update(_ entry: Entry) {
        queue.sync {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                entries[index] = entry
            }
            saveLocked()
        }
        onChange?()
    }

    /// Löscht ALLE Einträge samt zurückbehaltener Audio-Dateien ("Alle löschen"-Button).
    public func deleteAll() {
        queue.sync {
            for entry in entries {
                if let name = entry.audioFileName {
                    try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(name))
                }
            }
            entries = []
            saveLocked()
        }
        onChange?()
    }

    /// Löscht die Audio-Datei eines Eintrags (nach erfolgreicher Nach-Transkription).
    public func deleteAudio(for entry: Entry) {
        guard let name = entry.audioFileName else { return }
        try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(name))
    }

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Hinweis: dateDecodingStrategy beim Laden muss dazu passen — siehe init.
        try? encoder.encode(entries).write(to: historyFile, options: .atomic)
    }
}
