import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
import LinuxNative
#else
import Darwin
import CryptoKit
#endif

/// Rechnet Byte-Zahlen in die Einheit um, in der Oberfläche und CLI Modellgrößen
/// nennen.
///
/// Steht bewusst an EINER Stelle: App und CLI zeigen dieselben Downloads an und
/// müssen dieselbe Zahl nennen. Vorher stand der Teiler siebenmal im Code — ein
/// Vertipper (1_000_000 statt 1_048_576) wäre nur an einer der Stellen aufgefallen.
public enum ByteSize {
    /// Bytes als ganze Mebibyte. Abgerundet, weil die Zahl nur zur Anzeige dient.
    public static func megabytes(_ bytes: Int64) -> Int64 { bytes / 1_048_576 }
}

/// Beschafft das Whisper-Modell selbst, damit die App auf einem nackten Mac
/// benutzbar ist.
///
/// Bewusst nur ZWEI Modelle im Angebot (Entscheidung, die die App dem Nutzer
/// abnimmt, statt ihn mit einer Modell-Liste alleinzulassen):
///  - `large-v3-turbo` (~1,6 GB): der Standard, beste Mischung aus Qualität und Tempo.
///  - `large-v3` (~3,1 GB): die einzige Alternative nach oben, für den Fall, dass
///    Fremdwörter und Fachbegriffe besser getroffen werden müssen.
/// Kleinere Modelle gibt es absichtlich nicht — schlechtere Erkennung will niemand,
/// und so groß ist Turbo nicht.
public struct WhisperModel: Equatable, Sendable {
    /// Modellname, wie ihn whisper.cpp kennt (z. B. "large-v3-turbo").
    public let name: String
    /// Größe der veröffentlichten Datei in Bytes. Die Anzeige rundet sie ab.
    public let approximateBytes: Int64
    let sha256: String
    /// Einzeiler für die Oberfläche.
    public let summary: String

    /// Dieselbe ungefähre Größe in MB, wie App und CLI sie vor dem Download nennen.
    public var approximateMegabytes: Int64 { ByteSize.megabytes(approximateBytes) }

    /// Dateiname im Modell-Ordner, in der Namenskonvention von whisper.cpp.
    public var fileName: String { "ggml-\(name).bin" }

    /// Offizielle ggml-Modelle des whisper.cpp-Projekts auf Hugging Face.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(ModelCatalog.revision)/\(fileName)")!
    }
}

public enum ModelCatalog {
    static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    public static let turbo = WhisperModel(
        name: "large-v3-turbo",
        approximateBytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        summary: L10n.text("model.summary.turbo")
    )
    public static let largeV3 = WhisperModel(
        name: "large-v3",
        approximateBytes: 3_095_033_483,
        sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        summary: L10n.text("model.summary.large_v3")
    )

    /// Was die App zur Auswahl anbietet. Reihenfolge = Empfehlung.
    public static let offered: [WhisperModel] = [turbo, largeV3]

    public static func model(named name: String) -> WhisperModel? {
        offered.first { $0.name == name }
    }
}

/// Lädt Modelle und sagt, ob am Zielpfad überhaupt eines liegt.
public final class ModelInstaller: Sendable {

    /// Was liegt am konfigurierten Modellpfad?
    public enum InstallState: Equatable, Sendable {
        /// Eine echte eigene Kopie — alles gut.
        case installed(path: String, bytes: Int64)
        /// Nur ein Verweis auf einen fremden Ort. Funktioniert HEUTE, aber das Modell
        /// gehört uns nicht: Räumt das fremde Programm auf, steht Stille Post ohne da.
        case borrowed(path: String, target: String)
        /// Kein Modell da.
        case missing(path: String)
    }

    public init() {}

    /// Prüft den Zielpfad, ohne etwas zu verändern.
    ///
    /// Wichtig und der Grund, warum das hier nicht einfach `fileExists` ist: Sowohl
    /// `FileManager.fileExists` als auch `[ -f ]` in der Shell FOLGEN Symlinks und
    /// melden für einen geliehenen Verweis fröhlich "ist da". `attributesOfItem`
    /// folgt nicht (lstat) und sieht den Verweis deshalb.
    public static func state(atPath rawPath: String) -> InstallState {
        let path = Config.expandPath(rawPath)
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: path) else {
            return .missing(path: path)
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = (try? manager.destinationOfSymbolicLink(atPath: path)) ?? "unbekannt"
            return .borrowed(path: path, target: target)
        }
        // Nur eine reguläre Datei kann whisper-server als Modell öffnen. Ein
        // Verzeichnis oder eine Spezialdatei gilt deshalb als fehlend; der
        // anschließende Installationsversuch benennt mit `targetNotReplaceable`
        // konkret, warum der Zielpfad nicht beschrieben werden darf.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .missing(path: path)
        }
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return .installed(path: path, bytes: bytes)
    }

    /// Fortschritt eines laufenden Downloads.
    /// `Sendable`, weil die Meldung aus dem Netzwerk-Task zur Oberfläche wandert.
    public struct Progress: Equatable, Sendable {
        public let receivedBytes: Int64
        public let totalBytes: Int64
        /// 0…1, oder nil solange die Gesamtgröße unbekannt ist.
        public var fraction: Double? {
            totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : nil
        }
        /// Ganze Prozent, oder nil solange die Gesamtgröße unbekannt ist.
        public var percent: Int? { fraction.map { Int($0 * 100) } }
        /// Geladen und erwartet in MB — die Zahlen, die Fortschrittstexte zeigen.
        public var receivedMegabytes: Int64 { ByteSize.megabytes(receivedBytes) }
        public var totalMegabytes: Int64 { ByteSize.megabytes(totalBytes) }
    }

    /// Lädt `model` nach `rawPath`. Bricht der Download ab, setzt der nächste Aufruf
    /// an der Abbruchstelle fort — bei 1,6 GB ist Neuanfangen keine Option.
    ///
    /// `onProgress` wird auf einem beliebigen Task aufgerufen, NICHT auf dem
    /// Main-Thread — die Oberfläche muss selbst dorthin zurückspringen.
    @discardableResult
    public func install(_ model: WhisperModel,
                        to rawPath: String,
                        onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> String {
        let path = Config.expandPath(rawPath)
        let partialPath = Self.partialPath(for: model, at: path)
        // Erst fragen, ob am Zielpfad überhaupt eine Modelldatei landen kann —
        // vor dem Download von 1,6 GB und vor jeder Änderung auf der Platte.
        // Dieselbe Prüfung steht unten noch einmal, direkt vor dem Verschieben.
        if Self.targetKind(atPath: path) == .unsupported {
            throw InstallError.targetNotReplaceable(path)
        }

        let lockFile = URL(fileURLWithPath: path).appendingPathExtension("lock")
        let descriptor: Int32
        do { descriptor = try AdvisoryFileLock.acquire(at: lockFile, nonBlocking: true) }
        catch let error as POSIXError where error.code == .EWOULDBLOCK {
            throw InstallError.alreadyInstalling
        }
        defer { _ = close(descriptor) }
        let expected = model.approximateBytes

        // Wie weit ist ein früherer Versuch gekommen?
        let alreadyHave = Self.resumeOffset(existing: try Self.partialFileSize(atPath: partialPath),
                                            expected: expected)

        if alreadyHave < expected {
            try await download(model, from: alreadyHave, expected: expected,
                               to: partialPath, onProgress: onProgress)
        }

        try Task.checkCancellation()
        try Self.publishPartial(at: partialPath, to: path, expected: expected, sha256: model.sha256)
        return path
    }

    static func publishPartial(at partialPath: String, to path: String, expected: Int64, sha256: String) throws {
        let finalSize = try Self.partialFileSize(atPath: partialPath)
        guard finalSize == expected else {
            throw InstallError.incomplete(got: finalSize, expected: expected, partialPath: partialPath)
        }

        guard try Self.digest(at: partialPath, expected: expected) == sha256 else {
            // Eine vollständige, falsche Datei kann nicht mehr fortgesetzt werden.
            let removed = partialPath.withCString { unlink($0) }
            if removed != 0 && errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            throw InstallError.checksumMismatch
        }
        try Task.checkCancellation()
        if Self.targetKind(atPath: path) == .unsupported {
            throw InstallError.targetNotReplaceable(path)
        }
        // rename ersetzt die alte Datei beziehungsweise den Link in einem Schritt.
        let result = partialPath.withCString { source in path.withCString { rename(source, $0) } }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func digest(at path: String, expected: Int64) throws -> String {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw InstallError.partialNotReplaceable(path) }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size == expected else { throw InstallError.partialNotReplaceable(path) }
#if os(Linux)
        var digest = [UInt8](repeating: 0, count: 32)
        guard sp_model_sha256(descriptor, UInt64(expected), &digest) == 1 else { throw CocoaError(.fileReadUnknown) }
        return digest.map { String(format: "%02x", $0) }.joined()
#else
        var digest = SHA256()
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var remaining = expected
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(min(1_048_576, remaining))), !chunk.isEmpty else {
                throw CocoaError(.fileReadUnknown)
            }
            digest.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
#endif
    }

    /// Pfad der Teildatei eines angefangenen Downloads.
    ///
    /// Der Modellname MUSS im Namen stehen. Beide angebotenen Modelle landen im
    /// selben Zielpfad — der steht als `whisper.modelPath` in der Konfiguration
    /// und ändert sich nicht, wenn man ein anderes Modell lädt. Hieß die
    /// Teildatei nur `<ziel>.partial`, dann setzte
    /// `stillepost-cli install-model large-v3` nach einem abgebrochenen
    /// Turbo-Download dessen Reste fort: Die Bereichsanfrage holte den Rest der
    /// ANDEREN Datei, am Ende stimmte die Gesamtgröße, und die
    /// Vollständigkeitsprüfung ließ eine aus zwei Modellen zusammengesetzte
    /// Datei durch. Mit dem Namen darin findet ein Modellwechsel schlicht keine
    /// passende Teildatei und lädt sauber von vorn.
    static func partialPath(for model: WhisperModel, at path: String) -> String {
        path + ".\(model.name).partial"
    }

    /// Ab welchem Byte darf ein abgebrochener Download fortsetzen?
    ///
    /// Nur eine Teildatei, die höchstens so lang ist wie die erwartete Datei,
    /// kann ihr Anfang sein. Ist sie LÄNGER, wurde das Modell am Server durch
    /// eine kleinere Fassung ersetzt — dann ist die 0 die richtige Antwort:
    /// `DownloadSink` kürzt die Teildatei bei Versatz 0 auf null und lädt sauber
    /// neu. Ohne diese Unterscheidung lud gar nichts mehr (die Teildatei gilt als
    /// „schon fertig“), und jeder weitere Versuch endete mit derselben Meldung
    /// über eine unvollständige Datei, die niemand von Hand wegräumt.
    static func resumeOffset(existing: Int64, expected: Int64) -> Int64 {
        existing <= expected ? existing : 0
    }

    private func download(_ model: WhisperModel,
                          from offset: Int64,
                          expected: Int64,
                          to partialPath: String,
                          onProgress: (@Sendable (Progress) -> Void)?) async throws {
        var request = URLRequest(url: model.downloadURL)
        if offset > 0 {
            // Genau das, was `curl -C -` macht: nur den Rest anfordern.
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        // Warum dieser umständliche Weg mit eigenem Session-Delegate?
        //
        //  - `session.bytes(for:)` liefert eine AsyncSequence EINZELNER Bytes. Bei
        //    1,6 GB wären das über eine Milliarde async-Iterationen — unbrauchbar.
        //  - `session.download(for:delegate:)` nimmt laut Signatur nur einen
        //    `URLSessionTaskDelegate`. `didWriteData` gehört aber zum
        //    `URLSessionDownloadDelegate` und wird deshalb NIE aufgerufen —
        //    gemessen: null Fortschrittsmeldungen, mit `.shared` wie mit eigener
        //    Session. Ohne Fortschritt steht der Nutzer 1,6 GB lang vor einem
        //    toten Fenster.
        //
        // Ein Data-Task mit Session-Delegate bekommt die Antwort in Blöcken; wir
        // schreiben selbst und wissen dadurch jederzeit, wie weit wir sind.
        let sink = DownloadSink(partialPath: partialPath,
                                requestedOffset: offset,
                                expected: expected,
                                modelName: model.name,
                                onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: sink, delegateQueue: nil)
        // Ohne Invalidierung hält die Session ihren Delegate für immer fest.
        defer { session.finishTasksAndInvalidate() }
        try await sink.run(session: session, request: request)
    }

    /// Schreibt die Antwort blockweise in die Teildatei und meldet den Fortschritt.
    private final class DownloadSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partialPath: String
        private let requestedOffset: Int64
        private let expected: Int64
        private let modelName: String
        private let onProgress: (@Sendable (Progress) -> Void)?

        private let lock = NSLock()
        private var handle: FileHandle?
        private var received: Int64 = 0
        private var continuation: CheckedContinuation<Void, Error>?
        private var failure: Error?
        private var downloadTask: URLSessionDataTask?
        private var cancelled = false

        init(partialPath: String, requestedOffset: Int64, expected: Int64,
             modelName: String, onProgress: (@Sendable (Progress) -> Void)?) {
            self.partialPath = partialPath
            self.requestedOffset = requestedOffset
            self.expected = expected
            self.modelName = modelName
            self.onProgress = onProgress
        }

        func run(session: URLSession, request: URLRequest) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let task = lock.withLock { () -> URLSessionDataTask? in
                        guard !cancelled else { return nil }
                        let task = session.dataTask(with: request)
                        self.continuation = continuation
                        downloadTask = task
                        return task
                    }
                    if let task { task.resume() }
                    else { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let task = lock.withLock {
                    cancelled = true
                    return downloadTask
                }
                task?.cancel()
            }
        }

        /// Kopf der Antwort: Hier entscheidet sich, ob angehängt oder neu geschrieben wird.
        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            // 200 = von vorn, 206 = Teilbereich. Alles andere abbrechen, sonst
            // landet eine HTML-Fehlerseite in der Modell-Datei.
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 206 else {
                lock.lock(); failure = InstallError.unavailable(modelName); lock.unlock()
                completionHandler(.cancel)
                return
            }
            // Bei 206 muss der Server GENAU den angeforderten Bereich derselben
            // Datei liefern. Ohne diese Prüfung hängt jeder beliebige Teilbereich
            // an die vorhandene Teildatei an — hinterher stimmt nur noch die
            // Gesamtgröße, und die allein beweist nichts über den Inhalt.
            if http.statusCode == 206 {
                guard let range = ModelInstaller.contentRange(
                        http.value(forHTTPHeaderField: "Content-Range")),
                      range.start == requestedOffset, range.total == expected else {
                    lock.lock(); failure = InstallError.unavailable(modelName); lock.unlock()
                    completionHandler(.cancel)
                    return
                }
            }
            // Ignoriert der Server den Range-Wunsch (200 statt 206), enthält die
            // Antwort die GANZE Datei — dann darf nicht angehängt werden, sonst
            // entsteht Datenmüll aus altem Anfang plus vollständiger Datei.
            let append = requestedOffset > 0 && http.statusCode == 206
            do {
                // Ein vorhandener Symlink an der Teildatei darf nie verfolgt
                // werden. `FileHandle(forWritingTo:)` tat genau das und konnte
                // dadurch eine fremde Datei kürzen oder erweitern. `open` mit
                // O_NOFOLLOW bindet Prüfung und Schreibziel an EINEN Deskriptor.
                let opened = try ModelInstaller.openPartialFile(
                    atPath: partialPath,
                    append: append,
                    requestedOffset: requestedOffset
                )
                lock.lock()
                if append {
                    received = requestedOffset
                } else {
                    received = 0
                }
                handle = opened
                lock.unlock()
                completionHandler(.allow)
            } catch {
                lock.lock(); failure = error; lock.unlock()
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard let handle else { lock.unlock(); return }
            guard Int64(data.count) <= expected - received else {
                failure = InstallError.unavailable(modelName)
                lock.unlock()
                dataTask.cancel()
                return
            }
            do {
                try handle.write(contentsOf: data)
                received += Int64(data.count)
            } catch {
                failure = error
                lock.unlock()
                dataTask.cancel()
                return
            }
            let snapshot = Progress(receivedBytes: received, totalBytes: expected)
            lock.unlock()
            onProgress?(snapshot)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            do { try handle?.close() }
            catch { if failure == nil { failure = error } }
            handle = nil
            let pending = continuation
            continuation = nil
            downloadTask = nil
            let ownFailure = failure
            lock.unlock()

            // Eigene Diagnose schlägt den generischen Abbruchfehler, den `.cancel`
            // auslöst — sonst liest der Nutzer "abgebrochen" statt der Ursache.
            if let ownFailure {
                pending?.resume(throwing: ownFailure)
            } else if let error {
                pending?.resume(throwing: error)
            } else {
                pending?.resume()
            }
        }
    }

    /// Zerlegt den Kopf `Content-Range: bytes 100-199/1234` in Startversatz und
    /// Gesamtgröße. `nil` heißt: unbrauchbar — dann wird nicht angehängt.
    static func contentRange(_ header: String?) -> (start: Int64, total: Int64)? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst("bytes ".count).split(separator: "/")
        guard parts.count == 2,
              let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start, end < total else { return nil }
        return (start, total)
    }

    /// Öffnet eine Teildatei ohne Symlink-Folge und prüft Typ sowie
    /// Wiederaufnahme-Versatz auf demselben Deskriptor, der anschließend schreibt.
    /// Intern sichtbar für den Regressionstest, der eine fremde Symlink-Datei
    /// als Ziel unterlegt.
    static func openPartialFile(atPath path: String, append: Bool,
                                requestedOffset: Int64) throws -> FileHandle {
        // FIFO-Open darf nicht auf eine Gegenseite warten; erst danach kann
        // fstat den Dateityp auf demselben Deskriptor sicher prüfen.
        let descriptor = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw InstallError.partialNotReplaceable(path) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            _ = close(descriptor)
            throw InstallError.partialNotReplaceable(path)
        }

        if append {
            guard metadata.st_size == requestedOffset,
                  lseek(descriptor, 0, SEEK_END) == requestedOffset else {
                _ = close(descriptor)
                throw InstallError.partialNotReplaceable(path)
            }
        } else if ftruncate(descriptor, 0) != 0 {
            _ = close(descriptor)
            throw InstallError.partialNotReplaceable(path)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Größe einer regulären Teildatei. Ein fehlender Pfad bedeutet einen
    /// neuen Download; Symlinks und Spezialdateien werden ausdrücklich abgewiesen.
    static func partialFileSize(atPath path: String) throws -> Int64 {
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        if descriptor < 0 {
            if errno == ENOENT { return 0 }
            throw InstallError.partialNotReplaceable(path)
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw InstallError.partialNotReplaceable(path)
        }
        return Int64(metadata.st_size)
    }

    /// Was liegt am Zielpfad — und darf der Installer es ersetzen?
    enum TargetKind: Equatable {
        /// Nichts da, der Weg ist frei.
        case nothing
        /// Reguläre Datei oder Verweis: kann beim Verschieben ersetzt werden.
        case replaceable
        /// Verzeichnis oder Sonderdatei: wird nie angefasst.
        case unsupported
    }

    /// Bewusst nicht `fileExists`: Das folgt Symlinks und meldet für einen Verweis
    /// ins Leere "nichts da", obwohl der Verweis sehr wohl im Weg liegt.
    /// `attributesOfItem` (lstat) folgt nicht und sieht ihn — dieselbe Eigenschaft,
    /// auf der auch `state(atPath:)` beruht.
    static func targetKind(atPath path: String) -> TargetKind {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .nothing
        }
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular, .typeSymbolicLink:
            return .replaceable
        default:
            return .unsupported
        }
    }

    public enum InstallError: Error, LocalizedError, Equatable {
        case unavailable(String)
        case incomplete(got: Int64, expected: Int64, partialPath: String)
        /// Am Modellpfad liegt etwas, das kein Modell sein kann (z. B. ein
        /// Verzeichnis). Der Installer räumt dort nichts weg.
        case targetNotReplaceable(String)
        /// Die Download-Teildatei ist ein Verweis oder eine Spezialdatei und
        /// darf deshalb nicht als Schreibziel dienen.
        case partialNotReplaceable(String)
        case alreadyInstalling
        case checksumMismatch

        public var errorDescription: String? {
            switch self {
            case .unavailable(let name):
                return L10n.format("core.model.unavailable", name)
            case .incomplete(let got, let expected, let partialPath):
                return L10n.format("core.model.incomplete", got, expected, partialPath)
            case .targetNotReplaceable(let path):
                return L10n.format("core.model.target_not_replaceable", path)
            case .partialNotReplaceable(let path):
                return L10n.format("core.model.partial_not_replaceable", path)
            case .alreadyInstalling:
                return L10n.text("core.model.already_installing")
            case .checksumMismatch:
                return L10n.text("core.model.checksum_mismatch")
            }
        }
    }
}
