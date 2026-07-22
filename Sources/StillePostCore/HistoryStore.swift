import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    private let lockFile: URL
    private let atomicWrite: (Data, URL) throws -> Void
    private var entries: [Entry] = []
    /// Serielle Queue: Alle Zugriffe laufen hierüber, damit App-Thread und
    /// Pipeline-Tasks sich nicht in die Quere kommen.
    private let queue = DispatchQueue(label: "stillepost.history")

    public convenience init(baseDir: URL = Config.appSupportDir) {
        self.init(baseDir: baseDir) { data, url in
            try data.write(to: url, options: .atomic)
        }
    }

    /// Austauschbarer atomarer Schreiber ausschließlich für deterministische
    /// Fehlerpfad-Tests. Produktcode verwendet immer den Convenience-Initializer.
    init(baseDir: URL, atomicWrite: @escaping (Data, URL) throws -> Void) {
        historyFile = baseDir.appendingPathComponent("history.json")
        audioDir = baseDir.appendingPathComponent("recordings")
        lockFile = baseDir.appendingPathComponent("history.lock")
        self.atomicWrite = atomicWrite
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    // MARK: - Lesen

    /// Alle Einträge, neueste zuerst.
    public func list() throws -> [Entry] {
        try queue.sync {
            try withFileLock {
                entries = try loadFromDiskLocked()
                return entries.sorted { $0.date > $1.date }
            }
        }
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
    public func append(_ entry: Entry) throws {
        try queue.sync {
            try withFileLock {
                var fresh = try loadFromDiskLocked()
                fresh.append(entry)
                try saveLocked(fresh)
                entries = fresh
            }
        }
        onChange?()
    }

    /// Ersetzt einen Eintrag (z. B. nach "Erneut transkribieren") und speichert.
    public func update(_ entry: Entry) throws {
        try queue.sync {
            try withFileLock {
                var fresh = try loadFromDiskLocked()
                guard let index = fresh.firstIndex(where: { $0.id == entry.id }) else {
                    throw PersistenceError.entryNoLongerExists
                }
                fresh[index] = entry
                try saveLocked(fresh)
                entries = fresh
            }
        }
        onChange?()
    }

    /// Löscht ALLE Einträge samt zurückbehaltener Audio-Dateien ("Alle löschen"-Button).
    public func deleteAll() throws {
        var historyWasCleared = false
        defer {
            if historyWasCleared { onChange?() }
        }
        try queue.sync {
            try withFileLock {
                let fresh = try loadFromDiskLocked()
                // Erst der bestätigte atomare Plattenstand macht das Löschen der
                // nicht rekonstruierbaren Aufnahmen zulässig.
                try saveLocked([])
                entries = []
                historyWasCleared = true
                for entry in fresh {
                    if let name = entry.audioFileName {
                        try removeAudioFile(named: name)
                    }
                }
            }
        }
    }

    /// Löscht die Audio-Datei eines Eintrags (nach erfolgreicher Nach-Transkription).
    public func deleteAudio(for entry: Entry) throws {
        guard let name = entry.audioFileName else { return }
        try removeAudioFile(named: name)
    }

    private func loadFromDiskLocked() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: historyFile.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Entry].self, from: Data(contentsOf: historyFile))
    }

    private func saveLocked(_ entries: [Entry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try atomicWrite(encoder.encode(entries), historyFile)
    }

    /// `flock` schützt App und CLI gegeneinander. Entscheidend ist, dass Laden,
    /// Ändern und atomarer Schreibabschluss innerhalb desselben Locks liegen.
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = lockFile.path.withCString {
            open($0, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func removeAudioFile(named name: String) throws {
        guard !name.isEmpty, URL(fileURLWithPath: name).lastPathComponent == name else {
            throw PersistenceError.unsafeAudioFileName
        }
        let url = audioDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public enum PersistenceError: Error, LocalizedError {
        case entryNoLongerExists
        case unsafeAudioFileName

        public var errorDescription: String? {
            switch self {
            case .entryNoLongerExists:
                return L10n.text("core.history.entry_missing")
            case .unsafeAudioFileName:
                return L10n.text("core.history.unsafe_audio_name")
            }
        }
    }
}
