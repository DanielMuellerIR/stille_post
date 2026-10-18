import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Verlauf aller Diktate: Text ansehen/kopieren, fehlgeschlagene erneut
/// transkribieren, einzelne oder alle Einträge löschen.
///
/// Speicher-Prinzip (Datensparsamkeit):
///  - TEXT bleibt entsprechend der auftragsbezogenen Aufbewahrungsregel erhalten.
///  - Das AUDIO wird sofort nach ERFOLGREICHER Transkription gelöscht.
///  - Nur bei FEHLGESCHLAGENER Transkription bleibt die Audio-Datei liegen, damit
///    "Erneut transkribieren" möglich ist. Klappt der neue Versuch, wird sie dann
///    ebenfalls gelöscht.
public final class HistoryStore: @unchecked Sendable {

    /// Ein Eintrag im Verlauf.
    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public enum ResultOrigin: String, Codable, Sendable { case cleanup, rawFallback, manual }
        public struct ResultMetadata: Codable, Equatable, Sendable {
            public var date: Date
            public var origin: ResultOrigin
            public var generation: Int
            public var endpoint: String?
            public var durationSec: Double?
        }
        public struct Revision: Codable, Equatable, Sendable {
            public var text: String
            public var date: Date
            public var origin: ResultOrigin

            public init(text: String, date: Date, origin: ResultOrigin) {
                self.text = text
                self.date = date
                self.origin = origin
            }
        }
        public var id: UUID
        /// Zeitpunkt des Diktats (ISO-8601 beim Anzeigen formatiert).
        public var date: Date
        /// Roher Whisper-Text; bei Fehlern gegebenenfalls bereits erkannte Teilphasen.
        public var rawText: String
        /// Ausgabe; bei Fehlern gegebenenfalls unbereinigter Teiltext ohne Einfügen.
        public var cleanText: String
        /// "ok" oder "failed".
        public var status: String
        /// Fehlerbeschreibung bei status == "failed".
        public var errorMessage: String?
        /// Dateiname einer noch nicht nachweislich gelöschten Aufnahme.
        /// Bewusst nur der Name, kein absoluter Pfad — der Basis-Ordner kann sich ändern.
        public var audioFileName: String?
        /// nil bei älteren Einträgen; false sperrt Retry unvollständiger Arbeitskopien.
        public var audioIsComplete: Bool?
        /// Dauer der Aufnahme in Sekunden (fürs Anzeigen).
        public var durationSec: Double
        /// Wurde bei der Bereinigung auf den Rohtext zurückgefallen? (Diagnose)
        public var cleanupFellBack: Bool?
        /// WARUM wurde zurückgefallen bzw. teilweise zurückgesetzt? Ohne diesen
        /// Grund ließ sich im Verlauf nur raten, ob ein Endpoint down war oder die
        /// Worttreue-Prüfung die Modell-Ausgabe verworfen hat.
        public var cleanupFallbackReason: String?
        /// Welcher Endpoint der Kette hat bereinigt? (Diagnose: "war das der Fallback?")
        public var cleanupEndpoint: String?
        /// Wie lange hat die Bereinigung gedauert (Sekunden)? (Diagnose: "warum war
        /// das Diktat lahm — Bereinigung oder etwas anderes?")
        public var cleanupSec: Double?
        /// Text ist bereits gelöscht; nur eine noch zu entfernende Aufnahme bleibt.
        public var deletionPending: Bool?
        public var storesText: Bool?
        public var textExpiresAt: Date?
        public var audioExpiresAt: Date?
        public var originalCleanText: String?
        public var manualEditDate: Date?
        public var manualEditCount: Int?
        public var previousResults: [Revision]?
        public var resultMetadata: ResultMetadata?

        public var canEdit: Bool { status == "ok" && !isTextPrivate && !isDeletionPending }
        public var originalResultOrigin: ResultOrigin { cleanupFellBack == true ? .rawFallback : .cleanup }
        public var resultOrigin: ResultOrigin { resultMetadata?.origin ?? ((manualEditCount ?? 0) > 0 ? .manual : originalResultOrigin) }

        public var isAudioExpired: Bool { audioExpiresAt.map { $0 <= Date() } == true }

        public var canRetry: Bool {
            audioFileName != nil && audioIsComplete != false && !isDeletionPending && !isAudioExpired
        }

        public var diagnosticMessage: String? {
            if isDeletionPending { return L10n.text("core.history.audio_delete_pending") }
            if isTextPrivate {
                return L10n.text(isAudioExpired ? "core.history.private_audio_expired" : "core.history.private_audio")
            }
            return errorMessage
        }

        public var isTextPrivate: Bool {
            storesText == false || textExpiresAt.map { $0 <= Date() } == true
        }

        public var isFailed: Bool { status == "failed" }
        public var isDeletionPending: Bool {
            if let deletionPending { return deletionPending }
            // Frühere Versionen hatten noch kein Flag. Deren textfreie
            // Löschreste dürfen ebenfalls nicht erneut Text erhalten.
            guard isFailed, rawText.isEmpty, cleanText.isEmpty, audioFileName != nil else { return false }
            return ["de", "en"].contains {
                errorMessage == L10n.text("core.history.audio_delete_pending", language: $0)
            }
        }

        public init(id: UUID = UUID(), date: Date = Date(), rawText: String, cleanText: String,
                    status: String, errorMessage: String? = nil, audioFileName: String? = nil,
                    durationSec: Double, cleanupFellBack: Bool? = nil,
                    cleanupFallbackReason: String? = nil,
                    cleanupEndpoint: String? = nil, cleanupSec: Double? = nil,
                    deletionPending: Bool? = nil, storesText: Bool? = nil,
                    textExpiresAt: Date? = nil, audioExpiresAt: Date? = nil,
                    originalCleanText: String? = nil, manualEditDate: Date? = nil,
                    manualEditCount: Int? = nil, previousResults: [Revision]? = nil,
                    audioIsComplete: Bool? = nil) {
            self.id = id
            self.date = date
            self.rawText = rawText
            self.cleanText = cleanText
            self.status = status
            self.errorMessage = errorMessage
            self.audioFileName = audioFileName
            self.audioIsComplete = audioIsComplete
            self.durationSec = durationSec
            self.cleanupFellBack = cleanupFellBack
            self.cleanupFallbackReason = cleanupFallbackReason
            self.cleanupEndpoint = cleanupEndpoint
            self.cleanupSec = cleanupSec
            self.deletionPending = deletionPending
            self.storesText = storesText
            self.textExpiresAt = textExpiresAt
            self.audioExpiresAt = audioExpiresAt
            self.originalCleanText = originalCleanText
            self.manualEditDate = manualEditDate
            self.manualEditCount = manualEditCount
            self.previousResults = previousResults
        }
    }

    /// Wird nach jeder Änderung aufgerufen (fürs Aktualisieren des Verlaufsfensters).
    public var onChange: (() -> Void)?

    private let historyFile: URL
    private let audioDir: URL
    private let lockFile: URL
    private let atomicWrite: (Data, URL) throws -> Void
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
        try queue.sync { try listOnQueue() }
    }

    public func listAsync() async throws -> [Entry] {
        try await onQueue { try self.listOnQueue() }
    }

    private func listOnQueue() throws -> [Entry] {
        try withFileLock {
            // Maßgeblich ist immer der Plattenstand: App und CLI schreiben
            // beide in dieselbe Datei. Einen Zwischenspeicher gibt es
            // deshalb bewusst nicht.
            var fresh = try loadFromDiskLocked()
            try expireTextLocked(&fresh, now: Date())
            return fresh.sorted { $0.date > $1.date }
        }
    }

    /// Ordner, in dem fehlgeschlagene Aufnahmen liegen.
    public var recordingsDir: URL { audioDir }

    /// Absoluter Pfad zur Audio-Datei eines Eintrags (falls vorhanden).
    ///
    /// Der Name wird hier genauso geprüft wie beim Löschen: Er kommt aus
    /// `history.json` und darf den Aufnahme-Ordner nicht verlassen. „Erneut
    /// transkribieren“ liest die Datei über diesen Weg und schickte sonst eine
    /// beliebige Datei des Rechners an den whisper-server.
    public func audioURL(for entry: Entry) -> URL? {
        guard let name = entry.audioFileName.flatMap(Self.safeAudioName) else { return nil }
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
    @discardableResult
    public func append(_ entry: Entry) throws -> Entry {
        let receipt = try queue.sync { try appendOnQueue(entry) }
        onChange?()
        return receipt
    }

    /// Asynchrone Variante für die Diktier-Pipeline. Datei-Lock, JSON-Lesen und
    /// atomarer Write laufen auf der History-Queue statt auf dem Main-Thread.
    @discardableResult
    public func appendAsync(_ entry: Entry) async throws -> Entry {
        let cancellation = PendingAppendCancellation()
        let receipt = try await withTaskCancellationHandler {
            try await onQueue { try self.appendOnQueue(entry, cancellation: cancellation) }
        } onCancel: {
            cancellation.cancel()
        }
        onChange?()
        return receipt
    }

    /// Ersetzt einen Eintrag (z. B. nach "Erneut transkribieren") und speichert.
    @discardableResult
    public func update(_ entry: Entry) throws -> Entry {
        let receipt = try queue.sync { try updateOnQueue(entry) }
        onChange?()
        return receipt
    }

    /// Asynchrone Variante von `update`; siehe `appendAsync`.
    @discardableResult
    public func updateAsync(_ entry: Entry) async throws -> Entry {
        let receipt = try await onQueue { try self.updateOnQueue(entry) }
        onChange?()
        return receipt
    }

    /// Gemeinsamer Kern für synchrone und asynchrone Aufrufer. So können
    /// Lock-, Reload- und atomare Write-Reihenfolge nicht auseinanderlaufen.
    private func appendOnQueue(_ entry: Entry, cancellation: PendingAppendCancellation? = nil) throws -> Entry {
        try withFileLock {
            if cancellation?.isCancelled == true { throw CancellationError() }
            var fresh = try loadFromDiskLocked()
            let receipt = Self.effectiveEntry(entry, stored: nil, now: Date())
            if let persisted = Self.persistableEntry(receipt) {
                fresh.append(persisted)
                try saveLocked(fresh)
            }
            if cancellation?.isCancelled == true {
                try discardLocked(entry)
                throw CancellationError()
            }
            return receipt
        }
    }

    /// Abbruch verwirft ausschließlich diesen Text. Falls seine WAV noch
    /// existiert, bleibt ein textfreier Verweis für einen späteren Löschversuch.
    /// Das gilt auch, wenn der ursprüngliche Append noch nicht geschrieben hat.
    func discardAsync(_ entry: Entry) async throws {
        try await onQueue { try self.withFileLock { try self.discardLocked(entry) } }
        onChange?()
    }

    private func discardLocked(_ entry: Entry) throws {
        var fresh = try loadFromDiskLocked()
        // cancel() kennt vor einem Append nur den Audionamen. Beide Abbruchwege
        // müssen denselben Rest finden, statt doppelte Einträge anzulegen.
        let index = fresh.firstIndex(where: { $0.id == entry.id }) ??
            entry.audioFileName.flatMap { name in
                fresh.firstIndex(where: { $0.audioFileName == name })
            }
        let stored = index.map { fresh[$0] } ?? entry
        if let audio = audioURL(for: stored), FileManager.default.fileExists(atPath: audio.path) {
            let remnant = Self.audioOnlyRemnant(of: stored)
            if let index {
                if fresh[index] == remnant { return }
                fresh[index] = remnant
            } else {
                fresh.append(remnant)
            }
        } else if let index {
            fresh.remove(at: index)
        } else {
            return
        }
        try saveLocked(fresh)
    }

    /// Der Abbruch kommt vom Task, der Schreibbeginn von der seriellen Queue.
    /// Das Lock verbindet beide, ohne den Hauptthread am Plattenzugriff zu halten.
    private final class PendingAppendCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
    }

    private func updateOnQueue(_ entry: Entry) throws -> Entry {
        try withFileLock {
            var fresh = try loadFromDiskLocked()
            try expireTextLocked(&fresh, now: Date())
            guard let index = fresh.firstIndex(where: { $0.id == entry.id }) else {
                throw PersistenceError.entryNoLongerExists
            }
            guard !fresh[index].isDeletionPending else {
                throw PersistenceError.entryNoLongerExists
            }
            if fresh[index].isAudioExpired, entry.audioFileName != nil {
                throw PersistenceError.audioRetentionExpired
            }
            var input = entry
            if fresh[index].resultMetadata != nil || (fresh[index].manualEditCount ?? 0) > 0 {
                // Ein verspäteter Pipeline-Snapshot darf nur seinen Audioverweis
                // fortschreiben. Bestätigte Texte und deren Herkunft gehören dem Editor.
                guard entry.status == "ok", Self.sameText(entry.rawText, fresh[index].rawText),
                      entry.audioFileName == nil || entry.audioFileName == fresh[index].audioFileName else {
                    throw PersistenceError.correctionConflict
                }
                input = fresh[index]
                input.audioFileName = entry.audioFileName
                input = Self.effectiveEntry(input, stored: entry, now: Date())
            }
            let receipt = Self.effectiveEntry(input, stored: fresh[index], now: Date())
            if let persisted = Self.persistableEntry(receipt) { fresh[index] = persisted }
            else { fresh.remove(at: index) }
            try saveLocked(fresh)
            return receipt
        }
    }

    /// Optimistisches Speichern: ein veralteter Editor überschreibt weder eine
    /// jüngere Korrektur noch eine Löschung oder inzwischen abgelaufenen Text.
    /// `expected` stammt aus `list` oder einem vorherigen Korrektur-Save.
    public func saveCorrectionAsync(_ text: String, expected: Entry) async throws -> Entry {
        let receipt = try await onQueue {
            try self.withFileLock {
                var fresh = try self.loadFromDiskLocked()
                try self.expireTextLocked(&fresh, now: Date())
                guard let index = fresh.firstIndex(where: { $0.id == expected.id }) else {
                    throw PersistenceError.entryNoLongerExists
                }
                var current = fresh[index]
                guard current.canEdit else { throw PersistenceError.correctionUnavailable }
                guard Self.sameSnapshot(current, expected) else { throw PersistenceError.correctionConflict }
                guard !Self.sameText(current.cleanText, text) else { return current }
                let (count, overflow) = (current.manualEditCount ?? 0).addingReportingOverflow(1)
                guard !overflow else { throw PersistenceError.correctionConflict }
                var revisions = current.previousResults ?? []
                revisions.insert(.init(text: current.cleanText, date: current.resultMetadata?.date ?? current.manualEditDate ?? current.date,
                                       origin: current.resultOrigin), at: 0)
                if current.originalCleanText == nil { current.originalCleanText = current.cleanText }
                current.previousResults = Array(revisions.prefix(3))
                current.cleanText = text
                current.manualEditCount = count
                // JSON verwendet ISO-8601 ohne Sekundenbruchteile. Der Rückgabewert
                // muss beim nächsten Save denselben Snapshot wie die Platte ergeben.
                current.manualEditDate = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
                let (generation, generationOverflow) = (current.resultMetadata?.generation ?? 0).addingReportingOverflow(1)
                guard !generationOverflow else { throw PersistenceError.correctionConflict }
                current.resultMetadata = .init(date: current.manualEditDate!, origin: .manual, generation: generation)
                fresh[index] = current
                try self.saveLocked(fresh)
                return current
            }
        }
        onChange?()
        return receipt
    }

    /// Autorisiert eine Aktion anhand des frischen, noch editierbaren Eintrags.
    /// Der kurze synchrone Vorgang darf seinerseits nur den Config-Lock nehmen;
    /// Netzwerk und UI laufen immer außerhalb dieses History-Locks.
    public func withEditableSnapshotAsync<T: Sendable>(expected: Entry, action: @escaping @Sendable () throws -> T) async throws -> T {
        try await onQueue {
            try self.withFileLock {
                var fresh = try self.loadFromDiskLocked()
                try self.expireTextLocked(&fresh, now: Date())
                guard let current = fresh.first(where: { $0.id == expected.id }) else { throw PersistenceError.entryNoLongerExists }
                guard current.canEdit else { throw PersistenceError.correctionUnavailable }
                guard Self.sameSnapshot(current, expected) else { throw PersistenceError.correctionConflict }
                try Task.checkCancellation()
                return try action()
            }
        }
    }

    public func saveRecleanupAsync(_ result: CleanupService.Result, durationSec: Double, expected: Entry) async throws -> Entry {
        guard !result.usedFallback, result.endpoint != nil, durationSec.isFinite, durationSec >= 0,
              !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersistenceError.correctionUnavailable
        }
        let receipt = try await onQueue {
            try self.withFileLock {
                var fresh = try self.loadFromDiskLocked()
                try self.expireTextLocked(&fresh, now: Date())
                guard let index = fresh.firstIndex(where: { $0.id == expected.id }) else { throw PersistenceError.entryNoLongerExists }
                var current = fresh[index]
                guard current.canEdit else { throw PersistenceError.correctionUnavailable }
                guard Self.sameSnapshot(current, expected) else { throw PersistenceError.correctionConflict }
                let (generation, overflow) = (current.resultMetadata?.generation ?? 0).addingReportingOverflow(1)
                guard !overflow else { throw PersistenceError.correctionConflict }
                var revisions = current.previousResults ?? []
                revisions.insert(.init(text: current.cleanText, date: current.resultMetadata?.date ?? current.manualEditDate ?? current.date,
                                       origin: current.resultOrigin), at: 0)
                if current.originalCleanText == nil { current.originalCleanText = current.cleanText }
                current.previousResults = Array(revisions.prefix(3))
                current.cleanText = result.text
                current.resultMetadata = .init(date: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
                                               origin: .cleanup, generation: generation, endpoint: result.endpoint,
                                               durationSec: durationSec)
                fresh[index] = current
                try self.saveLocked(fresh)
                return current
            }
        }
        onChange?()
        return receipt
    }

    public static func sameText(_ first: String, _ second: String) -> Bool {
        first.utf8.elementsEqual(second.utf8)
    }

    private static func sameSnapshot(_ first: Entry, _ second: Entry) -> Bool {
        guard first == second, sameText(first.rawText, second.rawText), sameText(first.cleanText, second.cleanText),
              sameText(first.originalCleanText ?? "", second.originalCleanText ?? "") else { return false }
        return zip(first.previousResults ?? [], second.previousResults ?? []).allSatisfy { sameText($0.text, $1.text) }
    }

    /// Löscht nur den aktuellen Plattenstand dieser ID. Parallele Änderungen an
    /// anderen Einträgen bleiben unter demselben Prozess-Lock erhalten.
    public func delete(id: UUID) throws {
        defer { onChange?() }
        try queue.sync { try deleteOnQueue(id: id) }
    }

    public func deleteAsync(id: UUID) async throws {
        defer { onChange?() }
        try await onQueue { try self.deleteOnQueue(id: id) }
    }

    private func deleteOnQueue(id: UUID) throws {
        try withFileLock {
            var fresh = try loadFromDiskLocked()
            try deleteLocked(id: id, entries: &fresh)
        }
    }

    private func deleteLocked(id: UUID, entries fresh: inout [Entry]) throws {
        guard let index = fresh.firstIndex(where: { $0.id == id }) else { return }
        let entry = fresh[index]
        guard let name = entry.audioFileName else {
            fresh.remove(at: index)
            try saveLocked(fresh)
            return
        }
        guard Self.safeAudioName(name) != nil else {
            fresh.remove(at: index)
            try saveLocked(fresh)
            throw PersistenceError.unsafeAudioFileName
        }
        // Ein manuell duplizierter Audio-Verweis gehört weiter zum anderen
        // Eintrag. Seine Aufnahme darf die Einzellöschung nicht entfernen.
        if fresh.contains(where: { $0.id != id && $0.audioFileName == name }) {
            fresh.remove(at: index)
            try saveLocked(fresh)
            return
        }
        // Vor dem Dateizugriff den Löschauftrag dauerhaft festhalten. So
        // bleiben bei Dateifehler oder zweitem Write-Fehler alle Verweise da,
        // und ein verspätetes Retry darf den gelöschten Text nicht zurückholen.
        fresh[index] = Self.audioOnlyRemnant(of: entry)
        try saveLocked(fresh)
        try removeAudioFile(named: name)
        fresh.remove(at: index)
        try saveLocked(fresh)
    }

    /// Fristen gelten ausschließlich anhand der bereits gespeicherten Metadaten.
    /// Ein späterer Konfigurationswechsel verändert vorhandene Einträge nicht.
    public func applyRetentionAsync(now: Date = Date()) async throws {
        defer { onChange?() }
        try await onQueue {
            try self.withFileLock {
                var fresh = try self.loadFromDiskLocked()
                try self.expireTextLocked(&fresh, now: now)
                let ids = fresh.filter { $0.audioFileName != nil && $0.audioExpiresAt.map { $0 <= now } == true }.map(\.id)
                var firstError: Error?
                for id in ids {
                    do { try self.expireAudioLocked(id: id, entries: &fresh) }
                    catch { if firstError == nil { firstError = error } }
                }
                if let firstError { throw firstError }
            }
        }
    }

    private func expireAudioLocked(id: UUID, entries: inout [Entry]) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              let name = entries[index].audioFileName else { return }
        guard Self.safeAudioName(name) != nil else { throw PersistenceError.unsafeAudioFileName }
        let shared = entries.contains { $0.id != id && $0.audioFileName == name }
        if !shared { try removeAudioFile(named: name) }
        var completed = entries[index]
        completed.audioFileName = nil
        // Die Frist bleibt als Grenze gegen eine verspätete Wiederholung erhalten.
        if let retained = Self.persistableEntry(completed) { entries[index] = retained }
        else { entries.remove(at: index) }
        try saveLocked(entries)
    }

    private func expireTextLocked(_ entries: inout [Entry], now: Date) throws {
        let pruned = entries.compactMap { entry -> Entry? in
            Self.persistableEntry(Self.effectiveEntry(entry, stored: nil, now: now))
        }
        guard pruned != entries else { return }
        try saveLocked(pruned)
        entries = pruned
    }

    private static func earlier(_ first: Date?, _ second: Date?) -> Date? {
        if let first, let second { return min(first, second) }
        return first ?? second
    }

    /// Der Rückgabebeleg behält den fertigen Text ausschließlich im RAM; der
    /// persistierte Wert wird separat redigiert. Frische strengere Regeln gewinnen.
    private static func effectiveEntry(_ entry: Entry, stored: Entry?, now: Date) -> Entry {
        var result = entry
        result.textExpiresAt = earlier(entry.textExpiresAt, stored?.textExpiresAt)
        result.audioExpiresAt = earlier(entry.audioExpiresAt, stored?.audioExpiresAt)
        if entry.storesText == false || stored?.storesText == false ||
            result.textExpiresAt.map({ $0 <= now }) == true {
            result.storesText = false
        }
        return result
    }

    private static func persistableEntry(_ entry: Entry) -> Entry? {
        guard entry.storesText == false else {
            var bounded = entry
            if let revisions = entry.previousResults { bounded.previousResults = Array(revisions.prefix(3)) }
            return bounded
        }
        guard entry.audioFileName != nil else { return nil }
        var result = entry
        result.rawText = ""
        result.cleanText = ""
        result.cleanupFellBack = nil
        result.cleanupFallbackReason = nil
        result.cleanupEndpoint = nil
        result.cleanupSec = nil
        result.originalCleanText = nil
        result.manualEditDate = nil
        result.manualEditCount = nil
        result.previousResults = nil
        result.resultMetadata = nil
        result.status = "failed"
        result.errorMessage = nil
        return result
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
                // Vor JEDEM Löschversuch alle eigenen Audiodateien als
                // textfreie Reste persistieren. Endet der Prozess später oder
                // scheitert der abschließende Write, kennt der Plattenstand noch
                // jeden Namen, dessen Datei vorhanden sein könnte.
                var firstFailure: Error?
                let allRemnants = fresh.compactMap { entry -> Entry? in
                    guard let name = entry.audioFileName else { return nil }
                    guard Self.safeAudioName(name) != nil else {
                        if firstFailure == nil {
                            firstFailure = PersistenceError.unsafeAudioFileName
                        }
                        return nil
                    }
                    return Self.audioOnlyRemnant(of: entry)
                }
                try saveLocked(allRemnants)
                historyWasCleared = true
                // Jede Aufnahme einzeln versuchen. Bricht die Schleife beim ersten
                // Problem ab (unsicherer Name aus einer von Hand bearbeiteten
                // history.json, gesperrte Datei), bleiben alle danach kommenden
                // Aufnahmen liegen — und weil der Verlauf schon leer ist, kennt
                // ihre Namen dann niemand mehr. Gerade dieser Knopf soll keine
                // Aufnahme zurücklassen. Der erste Fehler wird nach der Schleife
                // gemeldet, damit das Scheitern trotzdem sichtbar bleibt.
                var survivors: [Entry] = []
                for entry in fresh {
                    guard let name = entry.audioFileName else { continue }
                    do {
                        try removeAudioFile(named: name)
                    } catch PersistenceError.unsafeAudioFileName {
                        // Ein Name, der aus dem Aufnahme-Ordner ausbricht, gehört
                        // uns nicht: Die Datei wird nie angefasst, und ein
                        // Platzhalter dafür würde den fremden Pfad für immer im
                        // Verlauf festhalten. Gemeldet wird der Fall trotzdem.
                        if firstFailure == nil { firstFailure = PersistenceError.unsafeAudioFileName }
                    } catch {
                        if firstFailure == nil { firstFailure = error }
                        // Eine echte eigene Aufnahme, die sich gerade nicht löschen
                        // ließ (Rechte, gesperrte Datei). Ihren Namen kennt nach dem
                        // Leeren sonst niemand mehr — ein zweiter Klick auf
                        // "Alle löschen" fände sie nicht. Deshalb bleibt ein
                        // minimaler Platzhalter zurück: nur der Dateiname, ohne den
                        // gelöschten Text.
                        survivors.append(Self.audioOnlyRemnant(of: entry))
                    }
                }
                // Auch der leere Endzustand wird geschrieben. Scheitert dieser
                // zweite Write, bleibt der sichere Reste-Stand vom Anfang liegen.
                try saveLocked(survivors)
                if let firstFailure { throw firstFailure }
            }
        }
    }

    /// Löscht die Audio-Datei eines Eintrags (nach erfolgreicher Nach-Transkription).
    public func deleteAudio(for entry: Entry) throws {
        guard let name = entry.audioFileName else { return }
        try removeAudioFile(named: name)
    }

    /// Der Rest eines Eintrags, dessen Aufnahme sich nicht löschen ließ: Text
    /// und Diagnosewerte sind weg (das war der Auftrag), der Verweis auf die
    /// verbliebene Datei bleibt.
    private static func audioOnlyRemnant(of entry: Entry) -> Entry {
        Entry(id: entry.id, date: entry.date, rawText: "", cleanText: "",
              status: "failed",
              errorMessage: L10n.text("core.history.audio_delete_pending"),
              audioFileName: entry.audioFileName,
              durationSec: entry.durationSec, deletionPending: true, storesText: false,
              textExpiresAt: entry.textExpiresAt, audioExpiresAt: entry.audioExpiresAt)
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

    /// Führt einen persistenten Vorgang auf derselben seriellen Queue wie die
    /// synchronen APIs aus, blockiert den aufrufenden Actor dabei aber nicht.
    private func onQueue<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    /// Gibt den Namen zurück, wenn er wirklich nur ein Dateiname ist — sonst nil.
    ///
    /// `lastPathComponent` ist hier das Maß: Bei „../woanders.wav“ oder
    /// „unter/ordner.wav“ liefert es etwas anderes als den Namen selbst, und
    /// genau daran erkennt man den Ausbruch aus dem Aufnahme-Ordner. Lesen und
    /// Löschen benutzen dieselbe Prüfung; eine Angabe, die zum Löschen zu
    /// unsicher ist, darf auch nicht gelesen werden.
    private static func safeAudioName(_ name: String) -> String? {
        // Beim Wurzelpfad ist lastPathComponent ebenfalls "/". Ohne diese
        // zusätzliche Grenze würde appendingPathComponent den Aufnahmeordner
        // selbst adressieren und eine Dateilöschung könnte ihn ganz entfernen.
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"),
              URL(fileURLWithPath: name).lastPathComponent == name else {
            return nil
        }
        return name
    }

    private func removeAudioFile(named name: String) throws {
        guard let name = Self.safeAudioName(name) else {
            throw PersistenceError.unsafeAudioFileName
        }
        let url = audioDir.appendingPathComponent(name)
        // unlink entfernt Dateien und Links, niemals rekursiv ein Verzeichnis.
        // Zugriffsfehler dürfen nicht wie ein fehlender Pfad behandelt werden.
        let (result, failure) = url.path.withCString { path in (unlink(path), errno) }
        guard result != 0 else { return }
        guard failure != ENOENT else { return }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }

    public enum PersistenceError: Error, LocalizedError {
        case correctionConflict
        case correctionUnavailable
        case audioRetentionExpired
        case entryNoLongerExists
        case unsafeAudioFileName

        public var errorDescription: String? {
            switch self {
            case .correctionConflict: return L10n.text("core.history.correction_conflict")
            case .correctionUnavailable: return L10n.text("core.history.correction_unavailable")
            case .audioRetentionExpired: return L10n.text("core.history.audio_expired")
            case .entryNoLongerExists:
                return L10n.text("core.history.entry_missing")
            case .unsafeAudioFileName:
                return L10n.text("core.history.unsafe_audio_name")
            }
        }
    }
}
