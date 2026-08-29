import Foundation

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
public struct WhisperModel: Equatable {
    /// Modellname, wie ihn whisper.cpp kennt (z. B. "large-v3-turbo").
    public let name: String
    /// Ungefähre Größe, nur für die Anzeige VOR dem Download ("Lade 1,6 GB?").
    /// Die verbindliche Größe holt der Installer per HEAD beim Laden.
    public let approximateBytes: Int64
    /// Einzeiler für die Oberfläche.
    public let summary: String

    /// Dieselbe ungefähre Größe in MB, wie App und CLI sie vor dem Download nennen.
    public var approximateMegabytes: Int64 { ByteSize.megabytes(approximateBytes) }

    /// Dateiname im Modell-Ordner, in der Namenskonvention von whisper.cpp.
    public var fileName: String { "ggml-\(name).bin" }

    /// Offizielle ggml-Modelle des whisper.cpp-Projekts auf Hugging Face.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

public enum ModelCatalog {
    public static let turbo = WhisperModel(
        name: "large-v3-turbo",
        approximateBytes: 1_624_555_275,
        summary: L10n.text("model.summary.turbo")
    )
    public static let largeV3 = WhisperModel(
        name: "large-v3",
        approximateBytes: 3_095_033_483,
        summary: L10n.text("model.summary.large_v3")
    )

    /// Was die App zur Auswahl anbietet. Reihenfolge = Empfehlung.
    public static let offered: [WhisperModel] = [turbo, largeV3]

    public static func model(named name: String) -> WhisperModel? {
        offered.first { $0.name == name }
    }
}

/// Lädt Modelle und sagt, ob am Zielpfad überhaupt eines liegt.
public final class ModelInstaller {

    /// Was liegt am konfigurierten Modellpfad?
    public enum InstallState: Equatable {
        /// Eine echte eigene Kopie — alles gut.
        case installed(path: String, bytes: Int64)
        /// Nur ein Verweis auf einen fremden Ort. Funktioniert HEUTE, aber das Modell
        /// gehört uns nicht: Räumt das fremde Programm auf, steht Stille Post ohne da.
        /// Genau diese Lage bestand auf dem Entwicklungsrechner (Verweis in den OpenWhispr-Cache).
        case borrowed(path: String, target: String)
        /// Kein Modell da.
        case missing(path: String)
    }

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private let session: URLSession

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
        let manager = FileManager.default

        // Erst fragen, ob am Zielpfad überhaupt eine Modelldatei landen kann —
        // vor dem Download von 1,6 GB und vor jeder Änderung auf der Platte.
        // Dieselbe Prüfung steht unten noch einmal, direkt vor dem Verschieben.
        if Self.targetKind(atPath: path) == .unsupported {
            throw InstallError.targetNotReplaceable(path)
        }

        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)

        let expected = try await expectedSize(of: model)

        // Wie weit ist ein früherer Versuch gekommen?
        let alreadyHave = Self.resumeOffset(existing: Self.fileSize(atPath: partialPath),
                                            expected: expected)

        if alreadyHave < expected {
            try await download(model, from: alreadyHave, expected: expected,
                               to: partialPath, onProgress: onProgress)
        }

        // Vollständigkeit belegen. Ohne diese Prüfung sieht eine abgebrochene
        // Wiederaufnahme aus wie ein Erfolg — und whisper-server scheitert später
        // an einer halben Datei, wo niemand die Ursache vermutet.
        let finalSize = Self.fileSize(atPath: partialPath)
        guard finalSize == expected else {
            throw InstallError.incomplete(got: finalSize, expected: expected, partialPath: partialPath)
        }

        // Was hier liegt, muss weg, bevor verschoben wird — und zwar der Verweis
        // selbst, nicht dessen Ziel. Der fremde Cache bleibt unangetastet.
        //
        // Entfernt wird dabei NUR eine reguläre Datei oder ein Verweis. Vorher
        // räumte diese Stelle alles weg, was am Modellpfad lag: Zeigte
        // `whisper.modelPath` durch einen Konfigurationsfehler auf ein
        // Verzeichnis, löschte `install-model --force` dessen gesamten Inhalt
        // rekursiv. Ein gescheitertes Entfernen wird außerdem nicht mehr
        // verschluckt — sonst scheiterte gleich darauf das Verschieben mit einer
        // Meldung, die die Ursache nicht nennt.
        switch Self.targetKind(atPath: path) {
        case .nothing:
            break
        case .replaceable:
            try manager.removeItem(atPath: path)
        case .unsupported:
            throw InstallError.targetNotReplaceable(path)
        }
        try manager.moveItem(atPath: partialPath, toPath: path)
        return path
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

    /// Verbindliche Größe per HEAD holen.
    private func expectedSize(of model: WhisperModel) async throws -> Int64 {
        var request = URLRequest(url: model.downloadURL)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError.unavailable(model.name)
        }
        // URLSession folgt der Hugging-Face-Weiterleitung aufs CDN selbst; die
        // erwartete Länge ist die der finalen Antwort.
        let size = http.expectedContentLength
        guard size > 1_000_000 else { throw InstallError.unavailable(model.name) }
        return size
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

        init(partialPath: String, requestedOffset: Int64, expected: Int64,
             modelName: String, onProgress: (@Sendable (Progress) -> Void)?) {
            self.partialPath = partialPath
            self.requestedOffset = requestedOffset
            self.expected = expected
            self.modelName = modelName
            self.onProgress = onProgress
        }

        func run(session: URLSession, request: URLRequest) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                session.dataTask(with: request).resume()
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
                let manager = FileManager.default
                if !append || !manager.fileExists(atPath: partialPath) {
                    manager.createFile(atPath: partialPath, contents: nil)
                }
                let opened = try FileHandle(forWritingTo: URL(fileURLWithPath: partialPath))
                lock.lock()
                if append {
                    try opened.seekToEnd()
                    received = requestedOffset
                } else {
                    try opened.truncate(atOffset: 0)
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
            try? handle?.close()
            handle = nil
            let pending = continuation
            continuation = nil
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
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return (start, total)
    }

    /// Größe der Datei am Pfad, oder 0 wenn dort nichts liegt.
    private static func fileSize(atPath path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value } ?? 0
    }

    /// Was liegt am Zielpfad — und darf der Installer es ersetzen?
    enum TargetKind: Equatable {
        /// Nichts da, der Weg ist frei.
        case nothing
        /// Reguläre Datei oder Verweis: darf vor dem Verschieben entfernt werden.
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

        public var errorDescription: String? {
            switch self {
            case .unavailable(let name):
                return L10n.format("core.model.unavailable", name)
            case .incomplete(let got, let expected, let partialPath):
                return L10n.format("core.model.incomplete", got, expected, partialPath)
            case .targetNotReplaceable(let path):
                return L10n.format("core.model.target_not_replaceable", path)
            }
        }
    }
}
