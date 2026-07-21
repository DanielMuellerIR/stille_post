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
    private let whisper: WhisperClient
    private let serverManager: WhisperServerManager
    private let cleanup: CleanupService

    // Zustand einer laufenden Aufnahme:
    private var recorder: AudioRecorder?
    private var segmenter: VadSegmenter?
    private var wavWriter: WavFileWriter?
    private var recordingStart: Date?
    private var sessionTask: Task<Void, Never>?
    /// Segment-Ergebnisse in Aufnahme-Reihenfolge (Index -> Text).
    private var segmentResults: SegmentCollector?

    public init(config: Config, history: HistoryStore? = nil) {
        self.config = config
        self.history = history ?? HistoryStore()
        self.whisper = WhisperClient(config: config.whisper)
        self.serverManager = WhisperServerManager(config: config.whisper)
        self.cleanup = CleanupService(config: config.cleanup)
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
        setState(.starting)

        Task { @MainActor in
            // 1. Mikrofon-Berechtigung sicherstellen (System fragt beim ersten Mal).
            guard await AudioRecorder.requestMicrophoneAccess() else {
                self.setState(.error(L10n.text("core.dictation.microphone_permission")))
                return
            }
            // 2. whisper-server sicherstellen (läuft er schon, kostet das nur einen Ping).
            do {
                try await self.serverManager.ensureRunning(client: self.whisper)
            } catch {
                self.setState(.error(error.localizedDescription))
                return
            }
            // shutdown()/Einstellungswechsel kann während des Server-Starts den
            // Zustand zurücksetzen. Dann weder Modell noch Startton der alten Engine
            // unnötig auslösen.
            guard self.state == .starting else { return }
            // 3. Bereinigungs-Modell VORWÄRMEN — lädt parallel, während man spricht.
            self.cleanup.warmUp()
            // 4. Startsignal vollständig VOR der Aufnahme abspielen. Unsere kurzen
            //    Sounds liegen deutlich über der VAD-Schwelle; in der Aufnahme
            //    würden sie deshalb als Sprache an Whisper geschickt.
            await self.onBeforeRecordingStart?()
            // Wurde die Engine während des asynchronen Startsignals beendet oder
            // neu aufgebaut, darf der alte Startvorgang kein Mikrofon mehr öffnen.
            guard self.state == .starting else { return }
            // 5. Aufnahme wirklich starten.
            self.beginRecording()
        }
    }

    private func beginRecording() {
        let segmenter = VadSegmenter(config: config.vad)
        let recorder = AudioRecorder(config: config.audio)
        let collector = SegmentCollector()
        segmentResults = collector

        // Komplette Aufnahme zusätzlich als WAV auf Platte puffern: Schlägt später
        // irgendetwas fehl, ist das Audio nicht weg ("Erneut transkribieren").
        // Nach ERFOLGREICHER Transkription wird die Datei sofort gelöscht.
        let wavURL = history.newRecordingURL()
        wavWriter = try? WavFileWriter(url: wavURL)

        // Fertige Segmente sofort transkribieren (läuft parallel weiter). Die
        // Bereinigung passiert absichtlich NICHT hier, sondern einmal am Ende über
        // den Gesamttext — nur so kann das LLM Satzgrenzen zwischen Segmenten
        // reparieren statt jedes Fragment als eigenen Satz zu behandeln.
        segmenter.onSegment = { [weak self] segment in
            guard let self, let collector = self.segmentResults else { return }
            // Reine Stille-Segmente überspringen: Whisper bekommt sie NIE zu sehen —
            // das ist die Abwesenheits-/Stille-Erkennung gegen Halluzinationen.
            guard segment.hadSpeech else { return }
            let index = collector.reserveSlot()
            Task {
                await collector.run(index: index) {
                    try await self.whisper.transcribe(samples: segment.samples)
                }
            }
        }

        // Abwesenheitserkennung: lange Stille -> Aufnahme automatisch beenden.
        segmenter.onAutoStop = { [weak self] in
            DispatchQueue.main.async { self?.stop() }
        }

        // Audio-Strom: an Segmentierer UND WAV-Datei verteilen.
        recorder.onSamples = { [weak self] samples in
            guard let self else { return }
            segmenter.process(samples)
            try? self.wavWriter?.append(samples)
        }

        do {
            try recorder.start()
        } catch {
            wavWriter = nil
            try? FileManager.default.removeItem(at: wavURL)
            setState(.error(L10n.format("core.dictation.recording_start_failed", error.localizedDescription)))
            return
        }

        self.recorder = recorder
        self.segmenter = segmenter
        self.recordingStart = Date()
        setState(.recording)
    }

    // MARK: - Aufnahme stoppen + Ergebnis bauen

    public func stop() {
        guard state == .recording, let recorder, let segmenter else { return }
        let duration = recordingDuration

        // Mikrofon zuerst schließen, erst danach den Verarbeitungszustand melden:
        // Die App spielt bei `.processing` den Stoppton. In umgekehrter Reihenfolge
        // wurde dieser Ton noch aufgenommen und als vermeintliche Sprache erkannt.
        recorder.stop()
        self.recorder = nil
        setState(.processing)
        segmenter.flush()  // letztes angefangenes Segment noch ausliefern
        self.segmenter = nil

        let writer = wavWriter
        self.wavWriter = nil
        try? writer?.finish()
        let wavURL = writer?.url

        guard let collector = segmentResults else { return }
        segmentResults = nil

        sessionTask = Task { @MainActor in
            // Auf alle noch laufenden Segment-Transkriptionen warten
            // (dank Streaming meist nur noch das letzte Segment).
            let segments = await collector.finish()

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
                self.history.append(entry)
                self.setState(.error(L10n.text("core.dictation.transcription_failed")))
                self.onResult?(DictationResult(text: "", entry: entry))
                return
            }

            // Erfolg: Audio sofort löschen (Datensparsamkeit — Text ist im Verlauf).
            if let wavURL { try? FileManager.default.removeItem(at: wavURL) }

            if rawJoined.isEmpty {
                // Nur Stille aufgenommen: nichts einfügen, keinen Verlaufs-Müll erzeugen.
                self.setState(.idle)
                self.onResult?(DictationResult(text: "", entry: nil))
                return
            }

            // Bereinigung über den GESAMTEN Text in einem Aufruf (Modell ist seit
            // Aufnahme-Start vorgewärmt). Bei Fehlern/Verdacht fällt clean() selbst
            // auf den Rohtext zurück — hier kommt immer verwendbarer Text an.
            let cleanupStarted = Date()
            let cleaned = await self.cleanup.clean(rawJoined)

            let entry = HistoryStore.Entry(
                rawText: rawJoined, cleanText: cleaned.text, status: "ok",
                durationSec: duration, cleanupFellBack: cleaned.usedFallback,
                cleanupEndpoint: cleaned.endpoint,
                cleanupSec: Date().timeIntervalSince(cleanupStarted)
            )
            self.history.append(entry)
            self.setState(.idle)
            self.onResult?(DictationResult(text: cleaned.text, entry: entry))
        }
    }

    /// Bricht eine laufende Aufnahme ab, ohne Text zu erzeugen (Menüpunkt "Abbrechen").
    public func cancel() {
        recorder?.stop()
        recorder = nil
        segmenter = nil
        segmentResults = nil
        if let writer = wavWriter {
            try? writer.finish()
            try? FileManager.default.removeItem(at: writer.url)
            wavWriter = nil
        }
        recordingStart = nil
        setState(.idle)
    }

    // MARK: - Erneut transkribieren (aus dem Verlauf)

    /// Transkribiert die zurückbehaltene Aufnahme eines fehlgeschlagenen Eintrags neu.
    /// Bei Erfolg wird der Eintrag aktualisiert und die Audio-Datei gelöscht.
    public func retry(entry: HistoryStore.Entry) async -> HistoryStore.Entry {
        guard let audioURL = history.audioURL(for: entry),
              FileManager.default.fileExists(atPath: audioURL.path) else {
            var updated = entry
            updated.errorMessage = L10n.text("core.dictation.audio_missing")
            history.update(updated)
            return updated
        }
        do {
            try await serverManager.ensureRunning(client: whisper)
            let raw = try await whisper.transcribe(wavFile: audioURL)
            let cleanupStarted = Date()
            let cleaned = await cleanup.clean(raw)
            var updated = entry
            updated.rawText = raw
            updated.cleanText = cleaned.text
            updated.status = "ok"
            updated.errorMessage = nil
            updated.cleanupFellBack = cleaned.usedFallback
            updated.cleanupEndpoint = cleaned.endpoint
            updated.cleanupSec = Date().timeIntervalSince(cleanupStarted)
            // Erfolg -> Aufnahme jetzt löschen (wie beim normalen Diktat).
            history.deleteAudio(for: entry)
            updated.audioFileName = nil
            history.update(updated)
            return updated
        } catch {
            var updated = entry
            updated.errorMessage = L10n.format("core.dictation.retry_failed", error.localizedDescription)
            history.update(updated)
            return updated
        }
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

    /// Fügt Segment-Texte zu einem Gesamttext zusammen.
    static func joinSegments(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func setState(_ newState: DictationState) {
        if case .recording = newState {} else if case .starting = newState {} else {
            recordingStart = nil
        }
        state = newState
        if Thread.isMainThread {
            onStateChange?(newState)
        } else {
            DispatchQueue.main.async { self.onStateChange?(newState) }
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
