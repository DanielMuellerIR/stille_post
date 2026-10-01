import Foundation

/// Zustand der Diktier-Maschine (für Menüleiste + Overlay).
public enum DictationState: Equatable {
    case idle                    // wartet auf den Hotkey
    case starting                // Dienste hochfahren / Mikro öffnen
    case recording               // Aufnahme läuft
    case processing              // Aufnahme beendet, letzte Segmente laufen noch
    case error(String)           // etwas ist schiefgegangen (Meldung fürs Overlay)
}

/// Das Ergebnis eines abgeschlossenen Diktats.
public struct DictationResult {
    /// Der fertige Text (bereinigt, oder roh bei Cleanup-Fallback). Leer = nur Stille.
    public let text: String
    /// Der zugehörige Verlaufs-Eintrag (nil, wenn nur Stille aufgenommen wurde).
    public let entry: HistoryStore.Entry?
}

/// Die zentrale Diktier-Maschine: verbindet Aufnahme, Stille-Erkennung,
/// Whisper-Transkription, LLM-Bereinigung und Verlauf.
///
/// Latenz-Konzept ("nie wieder 10 Sekunden warten"):
/// Der Audio-Strom wird schon WÄHREND der Aufnahme an Sprechpausen in Segmente
/// geschnitten. Jedes fertige Segment wird sofort transkribiert, parallel zur
/// weiterlaufenden Aufnahme. Die LLM-Bereinigung läuft dagegen bewusst EINMAL am
/// Ende über den zusammengefügten Gesamttext: Nur so sieht das Modell Satz-
/// zusammenhänge über Segmentgrenzen hinweg. (Vorher wurde pro Segment bereinigt —
/// das erzeugte Punkte mitten im Satz, weil jede Denkpause ein Segment beendet und
/// jedes Fragment isoliert zu einem "ganzen Satz" geputzt wurde.) Das Bereinigungs-
/// Modell wird beim Aufnahme-START vorgewärmt, damit kein Kaltstart in die
/// Wartezeit nach dem Stopp fällt.
public final class DictationEngine {

    // MARK: - Öffentliche Schnittstelle

    /// Zustands-Änderungen (App aktualisiert Menüleiste/Overlay). Auf Main-Thread.
    public var onStateChange: ((DictationState) -> Void)?
    /// Akustisches Startsignal unmittelbar vor dem Öffnen des Mikrofons. Die App
    /// wartet auf das Ende des Signals, damit der eigene Lautsprecherklang niemals
    /// im Diktat landet und von Whisper als Sprache fehlinterpretiert wird.
    public var onBeforeRecordingStart: (() async -> Void)?
    /// Fertiges Diktat (App fügt den Text ein). Auf Main-Thread.
    public var onResult: ((DictationResult) -> Void)?
    /// Die Bereinigung wechselt gerade auf einen Ausweich-Endpoint (Label als Text).
    /// Die App zeigt das im Overlay an — sonst wirkt ein Fallback nur wie
    /// unerklärliche Wartezeit. Auf Main-Thread.
    public var onCleanupFallback: ((String) -> Void)?
    /// Der primäre Bereinigungs-Endpoint antwortet gerade nicht, war aber eben
    /// noch da — die Bereinigung wartet ein paar Sekunden auf ihn (Blip-Toleranz).
    /// Auch das gehört ins Overlay. Auf Main-Thread.
    public var onCleanupPrimaryRetry: (() -> Void)?
    /// Live-Pegel in dBFS für die Anzeige (aufgerufen vom Audio-Thread!).
    public var currentLevelDb: Double { segmenter?.currentLevelDb ?? -120 }
    /// Laufende Aufnahmedauer in Sekunden.
    public var recordingDuration: TimeInterval { recordingStart.map { Date().timeIntervalSince($0) } ?? 0 }

    public private(set) var state: DictationState = .idle

    public let history: HistoryStore

    private let config: Config
    private let whisper: any DictationTranscriber
    private let serverManager: any DictationServer
    private let cleanup: any DictationCleanup
    private let makeRecorder: (Config.Audio) -> any DictationRecorder
    private let makeSegmenter: (Config.Vad) -> any DictationSegmenter
    private let makeWavWriter: (URL) throws -> any DictationWavWriter
    private let requestMicrophoneAccess: () async -> Bool
    /// Enge Testgrenze für die einzige asynchrone Nachverarbeitung nach Whisper.
    /// Produktiv zeigt sie immer direkt auf `CleanupService.clean`.
    private let cleanupText: (String) async -> CleanupService.Result

    // Zustand einer laufenden Aufnahme:
    private var recorder: (any DictationRecorder)?
    private var segmenter: (any DictationSegmenter)?
    private var wavWriter: (any DictationWavWriter)?
    private var recordingStart: Date?
    private var sessionTask: Task<Void, Never>?
    /// Jede Start-/Abbruchfolge bekommt eine neue Generation. Ein alter Task darf
    /// nach einem Await nur weiterarbeiten, wenn seine Generation noch aktiv ist.
    private var sessionGeneration: UInt64 = 0
    /// Segment-Ergebnisse in Aufnahme-Reihenfolge (Index -> Text).
    private var segmentResults: SegmentCollector?
    private var segmentTasks: RecordingSegmentTasks?
    private var recordingFailure: RecordingFailure?
    /// Die WAV-Datei, die gerade verarbeitet wird. `stop()` nimmt sie dem Writer
    /// ab; bis sie nachweislich gelöscht oder im Verlauf vermerkt ist, muss die
    /// Engine sie kennen — sonst hinterlässt ein Abbruch während `.processing`
    /// eine Aufnahme, auf die danach nichts mehr zeigt.
    private var processingWavURL: URL?

    public convenience init(config: Config, history: HistoryStore? = nil) {
        self.init(config: config, history: history, cleanupText: nil)
    }

    convenience init(config: Config, history: HistoryStore? = nil,
                     cleanupText: ((String) async -> CleanupService.Result)?) {
        self.init(
            config: config, history: history, dependencies: .live(config: config),
            cleanupText: cleanupText
        )
    }

    init(config: Config, history: HistoryStore? = nil,
         dependencies: DictationDependencies,
         cleanupText: ((String) async -> CleanupService.Result)? = nil) {
        self.config = config
        self.history = history ?? HistoryStore()
        self.whisper = dependencies.transcriber
        self.serverManager = dependencies.server
        let cleanup = dependencies.cleanup
        self.cleanup = cleanup
        self.makeRecorder = dependencies.makeRecorder
        self.makeSegmenter = dependencies.makeSegmenter
        self.makeWavWriter = dependencies.makeWavWriter
        self.requestMicrophoneAccess = dependencies.requestMicrophoneAccess
        self.cleanupText = cleanupText ?? { raw in await cleanup.clean(raw) }
        // Fallback-Wechsel der Bereinigung an die Oberfläche durchreichen
        // (CleanupService meldet von beliebigem Thread -> auf Main-Thread heben).
        self.cleanup.onFallbackEndpoint = { [weak self] label in
            DispatchQueue.main.async { self?.onCleanupFallback?(label) }
        }
        self.cleanup.onPrimaryRetry = { [weak self] in
            DispatchQueue.main.async { self?.onCleanupPrimaryRetry?() }
        }
    }

    /// Hotkey-Handler: startet die Aufnahme oder stoppt sie (Toggle).
    public func toggle() {
        switch state {
        case .idle, .error:
            start()
        case .recording:
            stop()
        case .starting, .processing:
            break  // Übergangszustände: Tastendruck ignorieren statt Chaos
        }
    }

    // MARK: - Aufnahme starten

    public func start() {
        guard state == .idle || {
            if case .error = state { return true } else { return false }
        }() else { return }
        sessionTask?.cancel()
        sessionTask = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        setState(.starting)

        Task { @MainActor in
            // 1. Mikrofon-Berechtigung sicherstellen (System fragt beim ersten Mal).
            guard await self.requestMicrophoneAccess() else {
                guard self.isCurrentSession(generation) else { return }
                self.setState(.error(L10n.text("core.dictation.microphone_permission")))
                return
            }
            guard self.isCurrentSession(generation), !Task.isCancelled else { return }
            // 2. whisper-server sicherstellen (läuft er schon, kostet das nur einen Ping).
            do {
                try await self.serverManager.ensureRunning(reachability: self.whisper)
            } catch {
                guard self.isCurrentSession(generation), !Task.isCancelled else { return }
                self.setState(.error(error.localizedDescription))
                return
            }
            // shutdown()/Einstellungswechsel kann während des Server-Starts den
            // Zustand zurücksetzen. Dann weder Modell noch Startton der alten Engine
            // unnötig auslösen.
            guard self.state == .starting, self.isCurrentSession(generation),
                  !Task.isCancelled else { return }
            // 3. Bereinigungs-Modell VORWÄRMEN — lädt parallel, während man spricht.
            self.cleanup.warmUp()
            // 4. Startsignal vollständig VOR der Aufnahme abspielen. Unsere kurzen
            //    Sounds liegen deutlich über der VAD-Schwelle; in der Aufnahme
            //    würden sie deshalb als Sprache an Whisper geschickt.
            await self.onBeforeRecordingStart?()
            // Wurde die Engine während des asynchronen Startsignals beendet oder
            // neu aufgebaut, darf der alte Startvorgang kein Mikrofon mehr öffnen.
            guard self.state == .starting, self.isCurrentSession(generation),
                  !Task.isCancelled else { return }
            // 5. Aufnahme wirklich starten.
            self.beginRecording(generation: generation)
        }
    }

    private func beginRecording(generation: UInt64) {
        guard isCurrentSession(generation) else { return }
        let segmenter = makeSegmenter(config.vad)
        let recorder = makeRecorder(config.audio)
        let collector = SegmentCollector()
        let recordingFailure = RecordingFailure()
        self.recordingFailure = recordingFailure
        let segmentTasks = RecordingSegmentTasks()
        self.segmentTasks = segmentTasks
        segmentResults = collector

        // Komplette Aufnahme zusätzlich als WAV auf Platte puffern: Schlägt später
        // irgendetwas fehl, ist das Audio nicht weg ("Erneut transkribieren").
        // Nach ERFOLGREICHER Transkription wird die Datei sofort gelöscht.
        let wavURL = history.newRecordingURL()
        let writer: any DictationWavWriter
        do {
            writer = try makeWavWriter(wavURL)
        } catch {
            segmentResults = nil
            setState(.error(L10n.format(
                "core.dictation.audio_writer_start_failed", wavURL.path,
                error.localizedDescription
            )))
            return
        }
        wavWriter = writer

        // Fertige Segmente sofort transkribieren (läuft parallel weiter). Die
        // Bereinigung passiert absichtlich NICHT hier, sondern einmal am Ende über
        // den Gesamttext — nur so kann das LLM Satzgrenzen zwischen Segmenten
        // reparieren statt jedes Fragment als eigenen Satz zu behandeln.
        // `collector` wird hier bewusst als lokaler Wert eingefangen und NICHT
        // über `self.segmentResults` gelesen: Der Callback läuft auf dem
        // Audio-Thread, während Start, Stopp und Abbruch dasselbe Feld auf dem
        // Hauptthread ersetzen. Neben dem Datenrennen konnte ein verspätetes
        // Segment so im Sammler einer schon neu begonnenen Aufnahme landen.
        segmenter.onSegment = { [weak self] segment in
            guard let self else { return }
            // Reine Stille-Segmente überspringen: Whisper bekommt sie NIE zu sehen —
            // das ist die Abwesenheits-/Stille-Erkennung gegen Halluzinationen.
            guard segment.hadSpeech else { return }
            segmentTasks.start(collector: collector) {
                try await self.whisper.transcribe(samples: segment.samples)
            }
        }

        // Abwesenheitserkennung: lange Stille -> Aufnahme automatisch beenden.
        segmenter.onAutoStop = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isCurrentSession(generation) else { return }
                self.stop()
            }
        }

        // Audio-Strom: an Segmentierer UND WAV-Datei verteilen.
        recorder.onSamples = { samples in
            segmenter.process(samples)
            // Der Writer merkt sich den ersten Fehler unter einem Lock. Der
            // Audio-Thread darf nicht blockierend UI-Zustand ändern; `stop()`
            // holt denselben Fehler beim Finalisieren sichtbar nach.
            do { try writer.append(samples) } catch {}
        }

        recorder.onFailure = { [weak self] error in
            // Das Fehlersignal wird sofort festgehalten. Ein unmittelbar folgender
            // Stopp darf nicht vorher den normalen Erfolgsweg starten.
            recordingFailure.record(error)
            if Thread.isMainThread {
                self?.failRecording(error, generation: generation)
            } else {
                DispatchQueue.main.async {
                    self?.failRecording(error, generation: generation)
                }
            }
        }

        do {
            try recorder.start()
        } catch {
            wavWriter = nil
            self.segmentTasks?.cancel()
            self.segmentTasks = nil
            self.recordingFailure = nil
            segmentResults = nil
            let startError = error
            do {
                try writer.finish()
                // Der Recorder kann schon Samples geliefert haben, bevor sein
                // Start scheitert. Deshalb auch hier keine Diagnose-WAV löschen.
                setState(.error(L10n.format(
                    "core.dictation.recording_start_failed_retained", wavURL.path,
                    startError.localizedDescription
                )))
            } catch {
                setState(.error(L10n.format(
                    "core.dictation.audio_write_failed", wavURL.path, error.localizedDescription
                )))
            }
            return
        }

        self.recorder = recorder
        self.segmenter = segmenter
        self.recordingStart = Date()
        setState(.recording)
        if let error = recordingFailure.error {
            failRecording(error, generation: generation)
        }
    }

    /// Ein unterbrochenes Mikrofon darf nicht den normalen Stopp auslösen:
    /// dessen Flush und Bereinigung würden aus einer Teilaufnahme einen Erfolg machen.
    private func failRecording(_ error: Error, generation: UInt64) {
        guard isCurrentSession(generation), state == .recording else { return }
        let duration = recordingDuration
        sessionGeneration &+= 1
        let failureGeneration = sessionGeneration
        sessionTask?.cancel()
        sessionTask = nil
        segmentTasks?.cancel()
        segmentTasks = nil
        recordingFailure = nil
        recorder?.stop()
        recorder = nil
        segmenter = nil
        segmentResults = nil
        let writer = wavWriter
        wavWriter = nil
        // Die Fehleraufnahme gehört ab jetzt zur Diagnose, nicht mehr zum
        // normalen Abbruchpfad, der aktive WAV-Dateien löschen darf.
        processingWavURL = nil
        let message = error.localizedDescription
        do {
            try writer?.finish()
        } catch {
            setState(.error(L10n.format(
                "core.dictation.audio_write_failed", writer?.url.path ?? "–",
                error.localizedDescription
            )))
            return
        }
        setState(.error(message))
        let entry = HistoryStore.Entry(
            rawText: "", cleanText: "", status: "failed", errorMessage: message,
            audioFileName: writer?.url.lastPathComponent, durationSec: duration
        )
        // Auch bei neuer Aufnahme bleibt der alte Fehlereintrag notwendig. Nur
        // seine verspätete UI-Meldung darf nicht den neuen Zustand überschreiben.
        Task { @MainActor in
            do {
                try await self.history.appendAsync(entry)
            } catch {
                guard self.isCurrentSession(failureGeneration) else { return }
                self.setState(.error(L10n.format(
                    "core.dictation.failure_history_write_failed", writer?.url.path ?? "–",
                    error.localizedDescription
                )))
            }
        }
    }

    // MARK: - Aufnahme stoppen + Ergebnis bauen

    public func stop() {
        guard state == .recording, let recorder, let segmenter else { return }
        let failureSignal = recordingFailure
        if let error = failureSignal?.error {
            failRecording(error, generation: sessionGeneration)
            return
        }
        let duration = recordingDuration

        // Mikrofon zuerst schließen, erst danach den Verarbeitungszustand melden:
        // Die App spielt bei `.processing` den Stoppton. In umgekehrter Reihenfolge
        // wurde dieser Ton noch aufgenommen und als vermeintliche Sprache erkannt.
        recorder.stop()
        self.recorder = nil
        // Auch während des Geräte-Stopps kann der Audio-Thread noch einen
        // Fehler melden. Erst danach darf der normale Verarbeitungsweg starten.
        if let error = failureSignal?.error {
            failRecording(error, generation: sessionGeneration)
            return
        }
        recordingFailure = nil
        setState(.processing)
        segmenter.flush()  // letztes angefangenes Segment noch ausliefern
        self.segmenter = nil

        let writer = wavWriter
        self.wavWriter = nil
        processingWavURL = writer?.url
        let wavURL: URL?
        do {
            try writer?.finish()
            wavURL = writer?.url
        } catch {
            // Unvollständiges Audio als Diagnose behalten, aber niemals als
            // angeblich erneut transkribierbare Aufnahme in den Verlauf hängen.
            // Die Datei bleibt absichtlich liegen; deshalb hier auch kein
            // Verweis, den ein späterer Abbruch wegräumen würde.
            processingWavURL = nil
            segmentResults = nil
            sessionGeneration &+= 1
            segmentTasks?.cancel()
            segmentTasks = nil
            sessionTask?.cancel()
            sessionTask = nil
            let retainedPath = writer?.url.path ?? "–"
            setState(.error(L10n.format(
                "core.dictation.audio_write_failed", retainedPath, error.localizedDescription
            )))
            return
        }

        guard let collector = segmentResults else {
            // Heute unerreichbar: `beginRecording` setzt den Sammler, bevor es
            // `.recording` meldet, und der Wächter oben verlangt genau diesen
            // Zustand. Ohne das Zurücksetzen bliebe die Maschine hier aber für
            // immer in `.processing` stehen — `toggle()` ignoriert diesen Zustand,
            // die App wäre bis zum Neustart taub. Ein Wächter darf keinen
            // Endzustand hinterlassen, aus dem es keinen Weg zurück gibt.
            setState(.idle)
            return
        }
        segmentResults = nil

        let generation = sessionGeneration
        sessionTask?.cancel()
        sessionTask = Task { @MainActor in
            defer {
                if self.isCurrentSession(generation) { self.sessionTask = nil }
            }
            // Auf alle noch laufenden Segment-Transkriptionen warten
            // (dank Streaming meist nur noch das letzte Segment).
            let segments = await collector.finish()
            if self.isCurrentSession(generation) { self.segmentTasks = nil }
            guard self.isCurrentSession(generation), !Task.isCancelled else { return }
            await self.finishSession(
                segments: segments, duration: duration, wavURL: wavURL,
                generation: generation
            )
        }
    }

    /// `@MainActor` ist hier Pflicht und kein Beiwerk: Die Funktion liest und
    /// schreibt `sessionGeneration`, `state` und `recordingStart` — dieselben
    /// Felder, die `start()`, `stop()` und `cancel()` auf dem Hauptthread
    /// anfassen. Als `nonisolated async`-Funktion lief sie auf dem globalen
    /// Concurrency-Executor; Zustandswechsel und der Abbruch-Wächter waren damit
    /// Datenrennen, und ein alter Verarbeitungslauf konnte einen neuen Zustand
    /// überschreiben. Die teure Arbeit bleibt trotzdem draußen: Die Bereinigung
    /// wird über `await` aufgerufen und läuft weiterhin außerhalb des Hauptthreads.
    @MainActor
    private func finishSession(segments: [String?], duration: TimeInterval,
                               wavURL: URL?, generation: UInt64) async {
        guard isCurrentSession(generation), !Task.isCancelled else { return }
        let failures = segments.filter { $0 == nil }.count
        let rawJoined = Self.joinSegments(segments.compactMap { $0 })

        if failures > 0 {
            // Mindestens ein Segment ist gescheitert (Server weg o. Ä.):
            // Audio-Datei BEHALTEN und als fehlgeschlagen in den Verlauf —
            // von dort aus kann man "Erneut transkribieren" klicken.
            // (Keine Bereinigung: Der Text ist ohnehin unvollständig; "Erneut
            // transkribieren" bereinigt später den vollständigen Text.)
            let entry = HistoryStore.Entry(
                rawText: rawJoined, cleanText: rawJoined,
                status: "failed",
                errorMessage: L10n.format("core.dictation.segments_failed", failures),
                audioFileName: wavURL?.lastPathComponent,
                durationSec: duration
            )
            guard isCurrentSession(generation), !Task.isCancelled else { return }
            do {
                try await history.appendAsync(entry)
            } catch {
                guard isCurrentSession(generation) else { return }
                setState(.error(L10n.format(
                    "core.history.persistence_failed", error.localizedDescription
                )))
                return
            }
            // Ab jetzt zeigt der Verlaufs-Eintrag auf die Aufnahme; die Engine
            // muss sie nicht mehr selbst im Auge behalten.
            guard isCurrentSession(generation), !Task.isCancelled else { return }
            processingWavURL = nil
            setState(.error(L10n.text("core.dictation.transcription_failed")))
            deliverResult(DictationResult(text: "", entry: entry))
            return
        }

        if rawJoined.isEmpty {
            // Nur Stille aufgenommen: nichts einfügen, keinen Verlaufs-Müll erzeugen.
            // Scheitert ausnahmsweise das Löschen, ist ein textfreier Fehler-Eintrag
            // aber kein Müll: Er hält den einzigen dauerhaften Verweis auf die WAV,
            // damit "Alle löschen" sie auch nach einem Neustart erneut versucht.
            if let wavURL {
                do {
                    try await Self.removeFileAsync(at: wavURL)
                    guard isCurrentSession(generation), !Task.isCancelled else { return }
                    processingWavURL = nil
                } catch {
                    let deletionError = error
                    let retained = HistoryStore.Entry(
                        rawText: "", cleanText: "", status: "failed",
                        errorMessage: L10n.format(
                            "core.history.audio_delete_failed",
                            deletionError.localizedDescription
                        ),
                        audioFileName: wavURL.lastPathComponent,
                        durationSec: duration
                    )
                    do {
                        try await history.appendAsync(retained)
                        guard isCurrentSession(generation), !Task.isCancelled else { return }
                        processingWavURL = nil
                    } catch {
                        guard isCurrentSession(generation) else { return }
                        setState(.error(L10n.format(
                            "core.history.persistence_failed", error.localizedDescription
                        )))
                        return
                    }
                    guard isCurrentSession(generation), !Task.isCancelled else { return }
                    deliverResult(DictationResult(text: "", entry: retained))
                    setState(.error(L10n.format(
                        "core.history.audio_delete_failed", deletionError.localizedDescription
                    )))
                    return
                }
            } else {
                processingWavURL = nil
            }
            guard isCurrentSession(generation), !Task.isCancelled else { return }
            setState(.idle)
            deliverResult(DictationResult(text: "", entry: nil))
            return
        }

        // Bereinigung über den GESAMTEN Text in einem Aufruf (Modell ist seit
        // Aufnahme-Start vorgewärmt). Bei Fehlern/Verdacht fällt clean() selbst
        // auf den Rohtext zurück — hier kommt immer verwendbarer Text an.
        let cleanupStarted = Date()
        let cleaned = await cleanupText(rawJoined)
        guard isCurrentSession(generation), !Task.isCancelled else { return }

        let entry = HistoryStore.Entry(
            rawText: rawJoined, cleanText: cleaned.text, status: "ok",
            durationSec: duration, cleanupFellBack: cleaned.usedFallback,
            cleanupFallbackReason: cleaned.fallbackReason,
            cleanupEndpoint: cleaned.endpoint,
            cleanupSec: Date().timeIntervalSince(cleanupStarted)
        )
        let finalized: PersistedEntryResult
        do {
            finalized = try await Self.persistSuccessfulEntry(
                entry,
                wavURL: wavURL,
                replacingExisting: false,
                history: history
            )
        } catch {
            guard isCurrentSession(generation) else { return }
            setState(.error(L10n.format(
                "core.history.persistence_failed", error.localizedDescription
            )))
            return
        }
        guard isCurrentSession(generation), !Task.isCancelled else { return }
        // Entweder ist die WAV gelöscht oder der bereits persistierte Eintrag
        // hält ihren Namen. In beiden Fällen darf die RAM-Verantwortung enden.
        processingWavURL = nil
        if let deletionError = finalized.deletionError {
            deliverResult(DictationResult(text: cleaned.text, entry: finalized.entry))
            setState(.error(L10n.format(
                "core.history.audio_delete_failed", deletionError
            )))
            return
        }
        if let persistenceError = finalized.persistenceError {
            // Text und erster Plattenstand sind bereits sicher, die WAV ist weg.
            // Ein Fehler nur beim Entfernen des nun veralteten Audio-Verweises
            // darf das fertige Diktat deshalb nicht verschlucken.
            deliverResult(DictationResult(text: cleaned.text, entry: finalized.entry))
            setState(.error(L10n.format(
                "core.history.persistence_failed", persistenceError
            )))
            return
        }
        setState(.idle)
        deliverResult(DictationResult(text: cleaned.text, entry: finalized.entry))
    }

    /// Ergebnis der gemeinsamen Disk-first-Operation für Live-Diktat und
    /// Wiederholung. Ein Löschfehler ist kein Persistenzfehler: Der Eintrag ist
    /// dann bereits MIT Audionamen gespeichert und bleibt erneut löschbar.
    private struct PersistedEntryResult {
        let entry: HistoryStore.Entry
        let deletionError: String?
        let persistenceError: String?
    }

    /// Speichert einen Erfolg zunächst mit Audio-Verweis, löscht danach die
    /// WAV und entfernt den Verweis erst nach bestätigtem Löschen. So kann kein
    /// zweiter Schreibfehler eine vorhandene Aufnahme verwaisen lassen.
    private static func persistSuccessfulEntry(
        _ entry: HistoryStore.Entry,
        wavURL: URL?,
        replacingExisting: Bool,
        history: HistoryStore
    ) async throws -> PersistedEntryResult {
        do {
            try Task.checkCancellation()
            let result = try await persistSuccessfulEntryUnchecked(
                entry, wavURL: wavURL, replacingExisting: replacingExisting, history: history
            )
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled && !replacingExisting {
                // Ein bereits gestarteter atomarer Write lässt sich nicht stoppen.
                // Nur unseren eigenen Eintrag zurücknehmen; fremde Diktate bleiben.
                try await history.discardAsync(entry)
            }
            throw error
        }
    }

    private static func persistSuccessfulEntryUnchecked(
        _ entry: HistoryStore.Entry, wavURL: URL?, replacingExisting: Bool,
        history: HistoryStore
    ) async throws -> PersistedEntryResult {
        guard let wavURL else {
            if replacingExisting {
                try await history.updateAsync(entry)
            } else {
                try await history.appendAsync(entry)
            }
            return PersistedEntryResult(
                entry: entry, deletionError: nil, persistenceError: nil
            )
        }

        var withAudio = entry
        withAudio.audioFileName = wavURL.lastPathComponent
        if replacingExisting {
            try await history.updateAsync(withAudio)
        } else {
            try await history.appendAsync(withAudio)
        }

        try Task.checkCancellation()
        do {
            try await removeFileAsync(at: wavURL)
        } catch {
            return PersistedEntryResult(
                entry: withAudio,
                deletionError: error.localizedDescription,
                persistenceError: nil
            )
        }

        try Task.checkCancellation()
        var withoutAudio = withAudio
        withoutAudio.audioFileName = nil
        do {
            try await history.updateAsync(withoutAudio)
            return PersistedEntryResult(
                entry: withoutAudio, deletionError: nil, persistenceError: nil
            )
        } catch HistoryStore.PersistenceError.entryNoLongerExists {
            // „Alle löschen“ hat den Eintrag parallel bewusst entfernt. Die WAV
            // ist ebenfalls weg; es gibt nichts mehr zu reparieren.
            return PersistedEntryResult(
                entry: withoutAudio, deletionError: nil, persistenceError: nil
            )
        } catch {
            // Der erste Stand mit Text und Audionamen liegt weiterhin auf der
            // Platte, nur der nun überflüssige Verweis konnte nicht entfernt
            // werden. Das ist sichtbar zu melden, aber kein Grund, Text zu verlieren.
            return PersistedEntryResult(
                entry: withAudio,
                deletionError: nil,
                persistenceError: error.localizedDescription
            )
        }
    }

    /// Dateisystemarbeit darf `finishSession` nicht auf dem MainActor festhalten.
    private static func removeFileAsync(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }.value
    }

    /// Bricht eine laufende Aufnahme ab, ohne Text zu erzeugen (Menüpunkt "Abbrechen").
    public func cancel() {
        let priorState = state
        let discardsActiveAudio: Bool
        switch priorState {
        case .starting, .recording, .processing:
            discardsActiveAudio = true
        case .idle, .error:
            discardsActiveAudio = false
        }
        sessionGeneration &+= 1
        sessionTask?.cancel()
        sessionTask = nil
        segmentTasks?.cancel()
        segmentTasks = nil
        recordingFailure = nil
        recorder?.stop()
        recorder = nil
        segmenter = nil
        segmentResults = nil
        var deletionFailure: Error?
        if let writer = wavWriter {
            if discardsActiveAudio {
                do {
                    try writer.finish()
                    try FileManager.default.removeItem(at: writer.url)
                } catch {
                    // Den einzigen bekannten Verweis nicht wegwerfen, solange
                    // weder das Löschen noch eine dauerhafte Ablage gelang.
                    processingWavURL = writer.url
                    deletionFailure = error
                }
            }
            wavWriter = nil
        }
        // Abbruch WÄHREND der Verarbeitung: Der Writer ist da längst weg, die
        // fertige WAV-Datei liegt aber noch auf der Platte. Ohne diesen Zweig
        // bliebe eine vollständige Aufnahme zurück, die im Verlauf nie auftaucht.
        if discardsActiveAudio, deletionFailure == nil, let pending = processingWavURL {
            do {
                try FileManager.default.removeItem(at: pending)
                processingWavURL = nil
            } catch {
                deletionFailure = error
            }
        }
        recordingStart = nil
        if let deletionFailure {
            setState(.error(L10n.format(
                "core.history.audio_delete_failed", deletionFailure.localizedDescription
            )))
        } else if case .error = priorState {
            // Ein Fehlerzustand besitzt seine Diagnoseaufnahme weiterhin. Vor
            // allem `shutdown()` und Einstellungen-Anwenden dürfen sie nicht als
            // vermeintlich aktiv abgebrochene Aufnahme löschen.
        } else {
            setState(.idle)
        }
    }

    // MARK: - Erneut transkribieren (aus dem Verlauf)

    /// Transkribiert die zurückbehaltene Aufnahme eines fehlgeschlagenen Eintrags neu.
    /// Bei Erfolg wird der Eintrag aktualisiert und die Audio-Datei gelöscht.
    public func retry(entry: HistoryStore.Entry) async throws -> HistoryStore.Entry {
        guard let audioURL = history.audioURL(for: entry),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            var updated = entry
            updated.errorMessage = L10n.text("core.dictation.audio_missing")
            try await history.updateAsync(updated)
            return updated
        }
        let raw: String
        do {
            try await serverManager.ensureRunning(reachability: whisper)
            // Wie beim Live-Diktat: Zeilenumbruch-Artefakte sofort deterministisch raus.
            raw = TranscriptPolish.flattenLineBreaks(try await whisper.transcribe(wavFile: audioURL))
        } catch {
            var updated = entry
            updated.errorMessage = L10n.format("core.dictation.retry_failed", error.localizedDescription)
            try await history.updateAsync(updated)
            return updated
        }
        let cleanupStarted = Date()
        let cleaned = await cleanup.clean(raw)
        var updated = entry
        updated.rawText = raw
        updated.cleanText = cleaned.text
        updated.status = "ok"
        updated.errorMessage = nil
        updated.cleanupFellBack = cleaned.usedFallback
        updated.cleanupFallbackReason = cleaned.fallbackReason
        updated.cleanupEndpoint = cleaned.endpoint
        updated.cleanupSec = Date().timeIntervalSince(cleanupStarted)
        let finalized = try await Self.persistSuccessfulEntry(
            updated,
            wavURL: audioURL,
            replacingExisting: true,
            history: history
        )
        if let deletionError = finalized.deletionError {
            throw AudioDeletionError(message: deletionError)
        }
        if let persistenceError = finalized.persistenceError {
            throw PersistenceCompletionError(message: persistenceError)
        }
        return finalized.entry
    }

    private struct AudioDeletionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct PersistenceCompletionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Hält das Bereinigungs-Modell geladen. Die App ruft das beim Start und
    /// periodisch auf — der AKTIVE Endpoint der Kette soll immer bereit sein,
    /// solange Stille Post läuft: normalerweise der primäre (nützt auch anderen
    /// Rechnern, die denselben Ollama-Endpoint als Bereinigungs-Server nutzen);
    /// ist der nicht erreichbar, wird stattdessen der Fallback vorgewärmt, damit
    /// sein Kaltstart nicht ins nächste Diktat fällt.
    public func keepCleanupModelWarm() {
        cleanup.warmUp()
    }

    /// Beim App-Ende: selbst gestarteten whisper-server mit beenden.
    public func shutdown() {
        cancel()
        serverManager.stop()
    }

    // MARK: - Hilfsfunktionen

    /// Fügt Segment-Texte zu einem Gesamttext zusammen. Whisper-Zeilenumbruch-
    /// Artefakte werden dabei schon deterministisch entfernt — so ist der Rohtext
    /// im Verlauf (und jeder Fallback) frei davon, unabhängig vom LLM.
    static func joinSegments(_ texts: [String]) -> String {
        texts
            .map { TranscriptPolish.flattenLineBreaks($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func setState(_ newState: DictationState) {
        if case .recording = newState {} else if case .starting = newState {} else {
            recordingStart = nil
        }
        state = newState
        Self.onMain { self.onStateChange?(newState) }
    }

    /// Liefert das fertige Diktat garantiert auf dem Main-Thread aus.
    private func deliverResult(_ result: DictationResult) {
        Self.onMain { self.onResult?(result) }
    }

    /// Ruft `work` auf dem Main-Thread auf — sofort, wenn wir schon dort sind.
    ///
    /// Warum jede Rückmeldung der Engine hier durchmuss: `onStateChange` und
    /// `onResult` fassen AppKit an (Statusicon, Overlay-Panel); AppKit bricht ab
    /// macOS 26 hart ab („Must only be used from the main thread“), wenn das
    /// off-main geschieht. Die Nachverarbeitung läuft seit dem `@MainActor` an
    /// `finishSession` selbst auf dem Hauptthread — diese Weiche bleibt als
    /// Sicherung für jeden künftigen Aufrufer, der es nicht ist.
    ///
    /// Die Weiche stand vorher zweimal wortgleich da — einmal je Rückmeldung.
    private static func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func isCurrentSession(_ generation: UInt64) -> Bool {
        generation == sessionGeneration
    }

    /// Startet nur die Nachverarbeitung ohne Mikrofon. Der schmale Testweg hält
    /// echte Aufnahme-/TCC-Zustände aus Lifecycle-Regressionen heraus.
    func processForTesting(rawText: String, duration: TimeInterval = 1,
                           wavURL: URL? = nil) {
        sessionTask?.cancel()
        sessionGeneration &+= 1
        let generation = sessionGeneration
        // Wie in `stop()`: Bis die Aufnahme nachweislich gelöscht oder im Verlauf
        // vermerkt ist, gehört sie der Engine.
        processingWavURL = wavURL
        setState(.processing)
        sessionTask = Task { @MainActor in
            defer {
                if self.isCurrentSession(generation) { self.sessionTask = nil }
            }
            await self.finishSession(
                segments: [rawText], duration: duration, wavURL: wavURL,
                generation: generation
            )
        }
    }
}

/// Sammelt die Ergebnisse der parallel laufenden Segment-Transkriptionen in der
/// richtigen Reihenfolge ein. Als Actor thread-sicher ohne manuelle Locks.
actor SegmentCollector {
    /// Ergebnis-Plätze (Rohtext je Segment) in Aufnahme-Reihenfolge.
    /// nil nach finish() = Segment gescheitert.
    private var slots: [String?] = []
    /// Wie viele Segmente sind komplett abgearbeitet (Erfolg ODER Fehler)?
    private var completedCount = 0
    /// Auf wie viele Segmente wartet finish()? (Int.max, solange finish() nicht lief)
    private var targetCount = Int.max
    private var continuation: CheckedContinuation<Void, Never>?

    /// Reserviert (synchron in Segment-Reihenfolge, vom Audio-Thread aus) einen
    /// Ergebnis-Platz. Läuft über eine kleine serielle Queue statt über den Actor,
    /// weil der Audio-Thread nicht awaiten kann und die Reihenfolge feststehen muss.
    nonisolated func reserveSlot() -> Int {
        reservationQueue.sync {
            let index = reservedCount
            reservedCount += 1
            return index
        }
    }
    private nonisolated(unsafe) var reservedCount = 0
    private nonisolated let reservationQueue = DispatchQueue(label: "stillepost.collector.reserve")

    /// Führt die Transkription eines Segments aus und legt das Ergebnis im Slot ab.
    func run(index: Int, _ work: () async throws -> String) async {
        while slots.count <= index { slots.append(nil) }
        do {
            slots[index] = try await work()
        } catch {
            slots[index] = nil  // gescheitertes Segment -> Aufrufer erkennt das an nil
        }
        completedCount += 1
        // Falls finish() schon wartet und wir das letzte offene Segment waren: aufwecken.
        if completedCount >= targetCount, let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    /// Wartet, bis ALLE reservierten Segmente fertig sind, und liefert die Slots.
    /// (Zählt über reservierte Plätze, nicht über gestartete Tasks — damit kann kein
    /// Segment "durchrutschen", dessen Task beim Stopp noch gar nicht lief.)
    func finish() async -> [String?] {
        let reserved = reservationQueue.sync { reservedCount }
        targetCount = reserved
        while completedCount < reserved {
            await withCheckedContinuation { self.continuation = $0 }
        }
        while slots.count < reserved { slots.append(nil) }
        return slots
    }
}

/// Der Audio-Thread kann noch einen Segment-Callback liefern, während der
/// Hauptthread bereits abbricht. Das Lock verhindert neue Tasks nach dem Abbruch
/// und storniert auch die schon laufenden Whisper-Anfragen.
private final class RecordingSegmentTasks {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [Task<Void, Never>] = []

    func start(collector: SegmentCollector, _ work: @escaping () async throws -> String) {
        lock.withLock {
            guard !cancelled else { return }
            // Reservierung und Task gehören zusammen: Auch ein sofort stornierter
            // Task muss seinen Platz abschließen, sonst wartet finish() endlos.
            let index = collector.reserveSlot()
            tasks.append(Task {
                await collector.run(index: index) {
                    try Task.checkCancellation()
                    return try await work()
                }
            })
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }
}

/// Recorder dürfen Fehler aus einem Audio-Callback melden. Das kurze Lock sichert
/// nur das Signal; Geräte-Stopp und UI-Zustand bleiben auf dem Hauptthread.
private final class RecordingFailure {
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.withLock { storedError } }

    func record(_ error: Error) {
        lock.withLock {
            if storedError == nil { storedError = error }
        }
    }
}
