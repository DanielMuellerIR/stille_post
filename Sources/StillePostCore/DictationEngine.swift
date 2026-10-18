import Foundation

/// Zustand der Diktier-Maschine (für Menüleiste + Overlay).
public enum DictationState: Equatable {
    case idle                    // wartet auf den Hotkey
    case starting                // Dienste hochfahren / Mikro öffnen
    case recording               // Aufnahme läuft
    case paused                  // Mikrofon freigegeben, bisherige Phasen bleiben erhalten
    case resuming                // Dienste/Startsignal, Mikrofon noch geschlossen
    case processing              // Aufnahme beendet, letzte Segmente laufen noch
    case error(String)           // etwas ist schiefgegangen (Meldung fürs Overlay)
}

/// Das Ergebnis eines abgeschlossenen Diktats.
public struct DictationResult {
    /// Der fertige Text (bereinigt, oder roh bei Cleanup-Fallback). Leer = nur Stille.
    public let text: String
    /// Der zugehörige Verlaufs-Eintrag (nil, wenn nur Stille aufgenommen wurde).
    public let entry: HistoryStore.Entry?

    public init(text: String, entry: HistoryStore.Entry?) {
        self.text = text
        self.entry = entry
    }
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

    /// Liest beim Auftragsstart ausschließlich die Identität der Ziel-App.
    public var requestAppBundleID: (() -> String?)?
    /// Zustands-Änderungen (App aktualisiert Menüleiste/Overlay). Auf Main-Thread.
    public var onStateChange: ((DictationState) -> Void)?
    /// Akustisches Startsignal unmittelbar vor dem Öffnen des Mikrofons. Die App
    /// wartet auf das Ende des Signals, damit der eigene Lautsprecherklang niemals
    /// im Diktat landet und von Whisper als Sprache fehlinterpretiert wird.
    public var onBeforeRecordingStart: (() async -> Void)?
    /// Fertiges Diktat für Ausgabe oder ausdrückliche Testvorschau. Auf Main-Thread.
    public var onResult: ((DictationResult) -> Void)?
    /// Flüchtiger Rohtext; nil entfernt die Anzeige. Auf dem Hauptthread.
    public var onTranscriptPreview: ((DictationTranscriptPreview?) -> Void)?
    public var onAudioImportStage: ((AudioImportStage) -> Void)?
    public private(set) var transcriptPreview: DictationTranscriptPreview?
    private var previewRevision = 0
    private var previewSuppressed = false
    public var isTranscriptPreviewEnabled: Bool { sessionRequest.config.ui.liveTranscriptPreview && !previewSuppressed }

    public func suppressTranscriptPreview() {
        previewSuppressed = true
        clearTranscriptPreview()
    }

    private func clearTranscriptPreview() {
        transcriptPreview = nil
        Self.onMain { self.onTranscriptPreview?(nil) }
    }
    /// Private Wiederholung: Ergebnis nur flüchtig anzeigen, niemals automatisch einfügen.
    public var onPrivateRetryResult: ((HistoryStore.Entry) -> Void)?
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
    /// Erfasste Audiozeit; Pause und Fortsetzungsvorbereitung zählen nicht mit.
    public var recordingDuration: TimeInterval { audioSession?.duration ?? 0 }

    /// Auf dem Hauptthread abfragen. Transkriptionszeiten summieren abgeschlossene
    /// Anfragen, die sich mit der Aufnahme und untereinander überlappen können.
    public var phaseTimings: DictationPhaseTimings { timingStore?.snapshot ?? .empty }

    public private(set) var state: DictationState = .idle

    public let history: HistoryStore

    private let requests: DictationRequestStore
    private var sessionRequest: DictationRequestStore.Snapshot
    public var sessionConfiguration: Config { sessionRequest.config }

    public func configure(_ config: Config) { requests.configure(config) }
    public func configureHistory(_ policy: Config.History) { requests.configureHistory(policy) }
    public func configureVocabulary(_ vocabulary: Config.Cleanup) { requests.configureVocabulary(vocabulary) }

    private func sessionEntry(_ entry: HistoryStore.Entry) -> HistoryStore.Entry {
        sessionRequest.config.history.applying(to: entry)
    }
    private let serverManager: any DictationServer
    private let makeRecorder: (Config.Audio) -> any DictationRecorder
    private let makeSegmenter: (Config.Vad) -> any DictationSegmenter
    private let makeWavWriter: (URL) throws -> any DictationWavWriter
    private let requestMicrophoneAccess: () async -> Bool
    private let monotonicTime: () -> TimeInterval
    private let beforeFileDecodeChunk: ((Int) async -> Void)?
    private var timingStore: DictationTimingStore?
    /// Enge Testgrenze für die einzige asynchrone Nachverarbeitung nach Whisper.
    /// Produktiv zeigt sie immer direkt auf `CleanupService.clean`.
    private let cleanupText: ((String) async -> CleanupService.Result)?

    // Zustand einer laufenden Aufnahme:
    private var recorder: (any DictationRecorder)?
    private var segmenter: (any DictationSegmenter)?
    private var wavWriter: (any DictationWavWriter)?
    private var audioSession: RecordingAudioSession?
    private var recordingPhaseID: UUID?
    private var closingAudioPhase = false
    private var startAttemptGeneration: UInt64 = 0
    private var sessionHoldCondition: () -> Bool = { true }
    private var sessionTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var importingAudio = false
    private var importCancellationRequested = false
    private var processingAudioIsComplete: Bool?
    private let retryLock = NSLock()
    private var retryTasks: [UUID: Task<HistoryStore.Entry, Error>] = [:]
    private var shuttingDown = false
    public var hasInFlightRequests: Bool {
        importingAudio || state == .starting || state == .recording || state == .paused || state == .resuming || state == .processing || retryLock.withLock { !retryTasks.isEmpty }
    }
    private var historyTasks: [UUID: Task<Void, Never>] = [:]
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
            config: config, history: history, dependencies: .live(config: config.resolvedForRequest()),
            cleanupText: cleanupText
        )
    }

    init(config: Config, history: HistoryStore? = nil,
         dependencies: DictationDependencies,
         cleanupText: ((String) async -> CleanupService.Result)? = nil) {
        let requests = DictationRequestStore(config: config, transcriber: dependencies.transcriber,
            cleanup: dependencies.cleanup, makeTranscriber: dependencies.makeTranscriber)
        self.requests = requests
        self.sessionRequest = requests.snapshot(appBundleID: requestAppBundleID?())
        self.history = history ?? HistoryStore()
        self.serverManager = dependencies.server
        let cleanup = dependencies.cleanup
        self.makeRecorder = dependencies.makeRecorder
        self.makeSegmenter = dependencies.makeSegmenter
        self.makeWavWriter = dependencies.makeWavWriter
        self.requestMicrophoneAccess = dependencies.requestMicrophoneAccess
        self.monotonicTime = dependencies.monotonicTime
        self.beforeFileDecodeChunk = dependencies.beforeFileDecodeChunk
        self.cleanupText = cleanupText
        // Fallback-Wechsel der Bereinigung an die Oberfläche durchreichen
        // (CleanupService meldet von beliebigem Thread -> auf Main-Thread heben).
        cleanup.onFallbackEndpoint = { [weak self] label in
            DispatchQueue.main.async { self?.onCleanupFallback?(label) }
        }
        cleanup.onPrimaryRetry = { [weak self] in
            DispatchQueue.main.async { self?.onCleanupPrimaryRetry?() }
        }
    }

    /// Hotkey-Handler: startet die Aufnahme oder stoppt sie (Toggle).
    public func toggle() {
        switch state {
        case .idle, .error:
            start()
        case .recording, .paused, .resuming:
            stop()
        case .starting, .processing:
            break  // Übergangszustände: Tastendruck ignorieren statt Chaos
        }
    }

    // MARK: - Aufnahme starten

    /// Import teilt Auftrags-Snapshot, Dienste und Endverarbeitung mit Diktaten.
    /// Die Quelldatei wird ausschließlich gelesen; nur die eigene WAV gehört uns.
    public func importAudioFile(_ source: URL, limits: AudioImportLimits = .shortClip) {
        guard !shuttingDown, !hasInFlightRequests, state == .idle || { if case .error = state { return true }; return false }() else { return }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        sessionRequest = requests.snapshot(appBundleID: requestAppBundleID?())
        let request = sessionRequest
        timingStore = DictationTimingStore(clock: monotonicTime)
        let timings = timingStore
        previewSuppressed = true; clearTranscriptPreview()
        let work = AudioFileImportWork(source: source, workingURL: history.newRecordingURL(), limits: limits,
            makeWriter: makeWavWriter, beforeChunk: beforeFileDecodeChunk)
        processingWavURL = work.workingURL
        processingAudioIsComplete = false
        importingAudio = true; importCancellationRequested = false
        setState(.processing)
        onAudioImportStage?(.decoding)
        sessionTask = Task { @MainActor in
            defer {
                if self.isCurrentSession(generation) {
                    self.importingAudio = false
                    self.processingAudioIsComplete = work.isComplete
                    if self.importCancellationRequested || Task.isCancelled { self.cancel() }
                    else { self.sessionTask = nil }
                }
            }
            do {
                try Task.checkCancellation()
                try await work.prepare()
                try Task.checkCancellation()
                timings?.finishPreparation()
                timings?.finishRecording(seconds: work.audioDuration)
                self.processingAudioIsComplete = true
                self.onAudioImportStage?(.transcribing)
                let texts = try await work.transcribe(request: request, server: self.serverManager,
                    makeSegmenter: self.makeSegmenter, timings: timings, clock: self.monotonicTime)
                try Task.checkCancellation()
                guard self.isCurrentSession(generation) else { return }
                if !texts.contains(where: { $0 == nil }), !Self.joinSegments(texts.compactMap { $0 }).isEmpty {
                    self.onAudioImportStage?(.cleaning)
                }
                await self.finishSession(segments: texts, duration: work.audioDuration,
                    wavURL: work.workingURL, generation: generation)
            } catch {
                guard self.isCurrentSession(generation), !Task.isCancelled else { return }
                await self.retainImportFailure(work, error: error, generation: generation)
            }
        }
        if importCancellationRequested { sessionTask?.cancel() }
    }

    @MainActor private func retainImportFailure(_ work: AudioFileImportWork, error: Error, generation: UInt64) async {
        let exists = FileManager.default.fileExists(atPath: work.workingURL.path)
        let message = exists ? L10n.format("audio_import.failed_with_audio", error.localizedDescription, work.workingURL.path) : error.localizedDescription
        let raw = Self.joinSegments(work.partialTexts)
        let entry = sessionEntry(HistoryStore.Entry(rawText: raw, cleanText: raw, status: "failed",
            errorMessage: message, audioFileName: exists ? work.workingURL.lastPathComponent : nil,
            durationSec: work.audioDuration, audioIsComplete: work.isComplete))
        do { try await history.appendAsync(entry) }
        catch {
            guard isCurrentSession(generation) else { return }
            setState(.error(L10n.format("core.history.persistence_failed", error.localizedDescription)))
            return
        }
        guard isCurrentSession(generation), !Task.isCancelled else {
            try? await history.discardAsync(entry)
            return
        }
        processingWavURL = nil
        setState(.error(message))
        deliverResult(DictationResult(text: "", entry: entry))
    }

    /// Die optionale Haltbedingung wird mehrfach gelesen und muss eine reine
    /// Zustandsabfrage sein. false bricht den noch laufenden Start ab.
    public func start(onlyWhile shouldContinue: @escaping () -> Bool = { true }) {
        guard !importingAudio else { return }
        guard state == .idle || {
            if case .error = state { return true } else { return false }
        }() else { return }
        guard shouldContinue() else { return }
        sessionTask?.cancel()
        sessionTask = nil
        processingAudioIsComplete = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration
        sessionRequest = requests.snapshot(appBundleID: requestAppBundleID?())
        previewSuppressed = false
        previewRevision = 0
        clearTranscriptPreview()
        timingStore = DictationTimingStore(clock: monotonicTime)
        setState(.starting)

        audioSession = RecordingAudioSession()
        sessionHoldCondition = shouldContinue
        prepareRecording(generation: generation, resuming: false)
    }

    public func pause() {
        guard state == .recording else { return }
        if let error = closeAudioPhase() {
            failRecording(error, generation: sessionGeneration)
            return
        }
        segmenter?.flush()
        segmenter = nil
        recordingFailure = nil
        setState(.paused)
    }

    public func resume() {
        guard state == .paused else { return }
        setState(.resuming)
        prepareRecording(generation: sessionGeneration, resuming: true)
    }

    private func cancelPreparation() {
        startAttemptGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
    }

    private func prepareRecording(generation: UInt64, resuming: Bool) {
        cancelPreparation()
        let attempt = startAttemptGeneration
        preparationTask = Task { @MainActor in
            defer { if self.startAttemptGeneration == attempt { self.preparationTask = nil } }
            guard self.canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
            let permitted = await self.requestMicrophoneAccess()
            guard self.canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
            guard permitted else {
                self.failPreparation(NSError(domain: "StillePost", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.text("core.dictation.microphone_permission")]),
                    generation: generation, resuming: resuming)
                return
            }
            do {
                try await self.serverManager.ensureRunning(reachability: self.sessionRequest.transcriber)
            } catch {
                guard self.canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
                self.failPreparation(error, generation: generation, resuming: resuming)
                return
            }
            guard self.canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
            if !resuming { self.sessionRequest.cleanup.warmUp() }
            await self.onBeforeRecordingStart?()
            guard self.canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
            self.beginRecording(generation: generation, attempt: attempt, resuming: resuming)
        }
    }

    private func failPreparation(_ error: Error, generation: UInt64, resuming: Bool) {
        if resuming { failRecording(error, generation: generation) }
        else { setState(.error(error.localizedDescription)) }
    }

    private func canContinueStart(generation: UInt64, attempt: UInt64, resuming: Bool) -> Bool {
        guard isCurrentSession(generation), startAttemptGeneration == attempt,
              state == (resuming ? .resuming : .starting), !Task.isCancelled else { return false }
        // Carbon-Freigabe und Poll-Timer können hinter einer Startfortsetzung
        // liegen. Die physische Bedingung gilt auch ohne zugestellten Callback.
        guard sessionHoldCondition() else {
            if resuming { stop() } else { cancel() }
            return false
        }
        return true
    }

    private func beginRecording(generation: UInt64, attempt: UInt64, resuming: Bool) {
        guard canContinueStart(generation: generation, attempt: attempt, resuming: resuming),
              let audioSession else { return }
        let segmenter = makeSegmenter(sessionRequest.config.vad)
        let recorder = makeRecorder(sessionRequest.config.audio)
        let previewEnabled = sessionRequest.config.ui.liveTranscriptPreview
        let reportPreview: ((Int, DictationTranscriptPreview) -> Void)? = previewEnabled ? { [weak self] revision, preview in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentSession(generation), !self.previewSuppressed,
                      self.sessionRequest.config.ui.liveTranscriptPreview,
                      self.state == .recording || self.state == .paused || self.state == .resuming,
                      revision > self.previewRevision else { return }
                self.previewRevision = revision
                self.transcriptPreview = preview
                self.onTranscriptPreview?(preview)
            }
        } : nil
        let collector = segmentResults ?? SegmentCollector(onPreview: reportPreview)
        let segmentTasks = self.segmentTasks ?? RecordingSegmentTasks()
        segmentResults = collector
        self.segmentTasks = segmentTasks
        let recordingFailure = RecordingFailure()
        self.recordingFailure = recordingFailure
        let writer: any DictationWavWriter
        if let existing = wavWriter { writer = existing }
        else {
            let wavURL = history.newRecordingURL()
            do { writer = try makeWavWriter(wavURL) }
            catch {
                segmentResults = nil
                setState(.error(L10n.format("core.dictation.audio_writer_start_failed", wavURL.path, error.localizedDescription)))
                return
            }
            wavWriter = writer
        }
        // Vor der bestätigten Fortsetzung darf auch ein synchron startender
        // Recorder keine neue Phase an die vorhandene Aufnahme anhängen.
        let phase = audioSession.beginPhase(acceptingSamples: !resuming)
        recordingPhaseID = phase
        let transcriber = sessionRequest.transcriber
        let timings = timingStore
        let clock = monotonicTime
        segmenter.onSegment = { segment in
            guard segment.hadSpeech else { return }
            segmentTasks.start(collector: collector) {
                let started = clock()
                defer { timings?.addTranscription(seconds: clock() - started) }
                return try await transcriber.transcribe(samples: segment.samples)
            }
        }
        segmenter.onAutoStop = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isCurrentSession(generation),
                      self.recordingPhaseID == phase, self.state == .recording else { return }
                self.stop()
            }
        }
        recorder.onSamples = { samples in
            audioSession.consume(samples, in: phase) {
                segmenter.process(samples)
                do { try writer.append(samples) } catch {}
            }
        }
        recorder.onFailure = { [weak self] error in
            recordingFailure.record(error)
            if Thread.isMainThread {
                guard let self, self.recordingPhaseID == phase, !self.closingAudioPhase,
                      self.state == .recording else { return }
                self.failRecording(error, generation: generation)
            } else {
                DispatchQueue.main.async {
                    guard let self, self.recordingPhaseID == phase, self.state == .recording else { return }
                    self.failRecording(error, generation: generation)
                }
            }
        }
        guard canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
        do { try recorder.start() }
        catch {
            if resuming {
                self.recorder = recorder
                failRecording(error, generation: generation)
            } else {
                audioSession.closePhase()
                recordingPhaseID = nil
                wavWriter = nil
                self.segmentTasks?.cancel()
                self.segmentTasks = nil
                self.recordingFailure = nil
                segmentResults = nil
                let startError = error
                do {
                    try writer.finish()
                    setState(.error(L10n.format("core.dictation.recording_start_failed_retained", writer.url.path, startError.localizedDescription)))
                } catch {
                    setState(.error(L10n.format("core.dictation.audio_write_failed", writer.url.path, error.localizedDescription)))
                }
            }
            return
        }
        self.recorder = recorder
        self.segmenter = segmenter
        guard canContinueStart(generation: generation, attempt: attempt, resuming: resuming) else { return }
        audioSession.acceptSamples(in: phase)
        setState(.recording)
        if recordingPhaseID == phase, state == .recording, let error = recordingFailure.error {
            failRecording(error, generation: generation)
        }
    }

    private func closeAudioPhase() -> Error? {
        audioSession?.closePhase()
        let failure = recordingFailure
        closingAudioPhase = true
        recorder?.stop()
        recorder = nil
        closingAudioPhase = false
        recordingPhaseID = nil
        return failure?.error
    }

    /// Ein unterbrochenes Mikrofon darf nicht den normalen Stopp auslösen:
    /// dessen Flush und Bereinigung würden aus einer Teilaufnahme einen Erfolg machen.
    private func failRecording(_ error: Error, generation: UInt64, writerAlreadyFailed: Bool = false) {
        guard isCurrentSession(generation), state == .recording || state == .paused || state == .resuming else { return }
        _ = closeAudioPhase()
        let duration = recordingDuration
        timingStore?.finishRecording(seconds: duration)
        cancelPreparation()
        sessionGeneration &+= 1
        let failureGeneration = sessionGeneration
        sessionTask?.cancel()
        sessionTask = nil
        let collector = segmentResults
        segmentTasks?.cancel()
        segmentTasks = nil
        recordingFailure = nil
        segmenter = nil
        segmentResults = nil
        let writer = wavWriter
        wavWriter = nil
        processingWavURL = nil
        var message = error.localizedDescription
        var validAudio = !writerAlreadyFailed
        if validAudio {
            do { try writer?.finish() }
            catch {
                validAudio = false
                message = L10n.format("core.dictation.audio_write_failed", writer?.url.path ?? "–", error.localizedDescription)
            }
        }
        setState(.error(message))
        let policy = sessionRequest.config.history
        let finalMessage = message
        let audioName = validAudio ? writer?.url.lastPathComponent : nil
        // Schon erkannte Phasen bleiben als unbereinigter Teiltext erhalten.
        // Die Politik muss vor dem Await feststehen, auch bei sofortigem Neustart.
        trackHistoryWork { @MainActor in
            let raw = Self.joinSegments(await collector?.completedTexts() ?? [])
            guard audioName != nil || !raw.isEmpty else { return }
            let entry = policy.applying(to: HistoryStore.Entry(
                rawText: raw, cleanText: raw, status: "failed", errorMessage: finalMessage,
                audioFileName: audioName, durationSec: duration,
                cleanupFellBack: true, cleanupFallbackReason: finalMessage
            ))
            do { try await self.history.appendAsync(entry) }
            catch {
                guard self.isCurrentSession(failureGeneration) else { return }
                self.setState(.error(L10n.format("core.dictation.failure_history_write_failed", writer?.url.path ?? "–", error.localizedDescription)))
            }
        }
    }

    // MARK: - Aufnahme stoppen + Ergebnis bauen

    public func stop() {
        guard state == .recording || state == .paused || state == .resuming else { return }
        cancelPreparation()
        if let error = closeAudioPhase() {
            failRecording(error, generation: sessionGeneration)
            return
        }
        let duration = recordingDuration
        timingStore?.finishRecording(seconds: duration)
        segmenter?.flush()
        segmenter = nil
        let writer = wavWriter
        do { try writer?.finish() }
        catch {
            let message = L10n.format("core.dictation.audio_write_failed", writer?.url.path ?? "–", error.localizedDescription)
            failRecording(NSError(domain: "StillePost", code: 1, userInfo: [NSLocalizedDescriptionKey: message]),
                generation: sessionGeneration, writerAlreadyFailed: true)
            return
        }
        recordingFailure = nil
        wavWriter = nil
        processingWavURL = writer?.url
        let wavURL = writer?.url
        guard let collector = segmentResults else {
            setState(.idle)
            return
        }
        segmentResults = nil
        // Erst nach geschlossener Hardware und abgeschlossener WAV darf die App
        // ihr Stoppsignal spielen. Pausen haben dieselbe Mikrofon-Grenze.
        setState(.processing)

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
    /// schreibt `sessionGeneration`, `state` und den Aufnahme-Lifecycle — dieselben
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
            let entry = sessionEntry(HistoryStore.Entry(
                rawText: rawJoined, cleanText: rawJoined,
                status: "failed",
                errorMessage: L10n.format("core.dictation.segments_failed", failures),
                audioFileName: wavURL?.lastPathComponent,
                durationSec: duration
            ))
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
            guard isCurrentSession(generation), !Task.isCancelled else {
                // Auch ein Fehlereintrag kann fertig geschrieben sein, bevor
                // der MainActor den Abbruch verarbeitet. Seinen Teiltext entfernen.
                try? await history.discardAsync(entry)
                return
            }
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
                    let retained = sessionEntry(HistoryStore.Entry(
                        rawText: "", cleanText: "", status: "failed",
                        errorMessage: L10n.format(
                            "core.history.audio_delete_failed",
                            deletionError.localizedDescription
                        ),
                        audioFileName: wavURL.lastPathComponent,
                        durationSec: duration
                    ))
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
        let cleanupStarted = monotonicTime()
        let cleanupTimings = timingStore
        let cleaned: CleanupService.Result
        if let cleanupText { cleaned = await cleanupText(rawJoined) }
        else { cleaned = await sessionRequest.cleanup.clean(rawJoined) }
        let cleanupDuration = max(0, monotonicTime() - cleanupStarted)
        cleanupTimings?.finishCleanup(seconds: cleanupDuration)
        guard isCurrentSession(generation), !Task.isCancelled else { return }

        let entry = sessionEntry(HistoryStore.Entry(
            rawText: rawJoined, cleanText: cleaned.text, status: "ok",
            durationSec: duration, cleanupFellBack: cleaned.usedFallback,
            cleanupFallbackReason: cleaned.fallbackReason,
            cleanupEndpoint: cleaned.endpoint,
            cleanupSec: cleanupDuration
        ))
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
        guard isCurrentSession(generation), !Task.isCancelled else {
            // Zwischen Rückkehr der Plattenarbeit und der Fortsetzung auf dem
            // MainActor kann Abbrechen laufen. Auch diesen bereits gespeicherten
            // eigenen Eintrag zurücknehmen, bevor die alte Session endet.
            try? await history.discardAsync(entry)
            return
        }
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
            let receipt = replacingExisting ? try await history.updateAsync(entry) : try await history.appendAsync(entry)
            return PersistedEntryResult(
                entry: receipt, deletionError: nil, persistenceError: nil
            )
        }

        var withAudio = entry
        withAudio.audioFileName = wavURL.lastPathComponent
        if replacingExisting {
            withAudio = try await history.updateAsync(withAudio)
        } else {
            withAudio = try await history.appendAsync(withAudio)
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
            withoutAudio = try await history.updateAsync(withoutAudio)
            return PersistedEntryResult(
                entry: withoutAudio, deletionError: nil, persistenceError: nil
            )
        } catch HistoryStore.PersistenceError.entryNoLongerExists {
            if replacingExisting { throw HistoryStore.PersistenceError.entryNoLongerExists }
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
        if importingAudio {
            importCancellationRequested = true
            sessionTask?.cancel()
            return
        }
        let priorState = state
        _ = closeAudioPhase()
        cancelPreparation()
        let duration = recordingDuration
        timingStore?.finishRecording(seconds: duration)
        let discardsActiveAudio: Bool
        switch priorState {
        case .starting, .recording, .paused, .resuming, .processing:
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
                if (error as NSError).domain == NSCocoaErrorDomain &&
                    (error as NSError).code == NSFileNoSuchFileError {
                    // Die erfolgreiche Plattenarbeit kann ihre eigene WAV schon
                    // gelöscht haben, bevor Abbrechen auf dem MainActor läuft.
                    processingWavURL = nil
                } else {
                    deletionFailure = error
                }
            }
        }
        audioSession = nil
        if let deletionFailure {
            setState(.error(L10n.format(
                "core.history.audio_delete_failed", deletionFailure.localizedDescription
            )))
            if let pending = processingWavURL {
                // Der ursprüngliche Append kann noch warten oder überhaupt nicht
                // existieren. Den Löschrest unabhängig vom stornierten Task sichern,
                // bevor ein späteres Diktat den RAM-Verweis ersetzt.
                let retained = sessionEntry(HistoryStore.Entry(
                    rawText: "", cleanText: "", status: "failed",
                    audioFileName: pending.lastPathComponent, durationSec: duration,
                    audioIsComplete: processingAudioIsComplete
                ))
                let generation = sessionGeneration
                trackHistoryWork { @MainActor in
                    do {
                        try await self.history.discardAsync(retained)
                        guard self.isCurrentSession(generation),
                              self.processingWavURL == pending else { return }
                        self.processingWavURL = nil
                    } catch {
                        guard self.isCurrentSession(generation) else { return }
                        self.setState(.error(L10n.format(
                            "core.history.persistence_failed", error.localizedDescription
                        )))
                    }
                }
            }
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
        let id = UUID()
        let request = requests.snapshot(appBundleID: requestAppBundleID?())
        let task: Task<HistoryStore.Entry, Error> = try retryLock.withLock {
            guard !shuttingDown else { throw CancellationError() }
            let task = Task { try await self.performRetry(entry: entry, request: request) }
            retryTasks[id] = task
            return task
        }
        defer { _ = retryLock.withLock { retryTasks.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func performRetry(entry: HistoryStore.Entry, request: DictationRequestStore.Snapshot) async throws -> HistoryStore.Entry {
        try Task.checkCancellation()
        let policy = request.config.history
        let requestCleanup = request.cleanup
        let whisper = request.transcriber
        guard let stored = (try await history.listAsync()).first(where: { $0.id == entry.id }),
              !stored.isDeletionPending else {
            throw HistoryStore.PersistenceError.entryNoLongerExists
        }
        guard !stored.isAudioExpired else {
            throw HistoryStore.PersistenceError.audioRetentionExpired
        }
        guard stored.audioIsComplete != false else { throw AudioImportFailure.incompleteAudio }
        var policyInput = stored
        policyInput.date = Date()
        var entry = policy.applying(to: policyInput)
        entry.date = stored.date
        entry.audioExpiresAt = stored.audioExpiresAt
        // Die Aufnahme behält ihre ursprüngliche Regel. Eine neue Textfrist
        // beginnt mit diesem Auftrag und verlängert keine vorhandene Frist.
        if stored.storesText == false { entry.storesText = false }
        if let expiry = stored.textExpiresAt {
            entry.textExpiresAt = entry.textExpiresAt.map { min($0, expiry) } ?? expiry
        }
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
            try Task.checkCancellation()
            var updated = entry
            updated.errorMessage = L10n.format("core.dictation.retry_failed", error.localizedDescription)
            try await history.updateAsync(updated)
            return updated
        }
        let cleanupStarted = Date()
        try Task.checkCancellation()
        let cleaned = await requestCleanup.clean(raw)
        try Task.checkCancellation()
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
        try Task.checkCancellation()
        if finalized.entry.isTextPrivate && !finalized.entry.cleanText.isEmpty {
            await MainActor.run { self.onPrivateRetryResult?(finalized.entry) }
        }
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
        requests.snapshot(appBundleID: requestAppBundleID?()).cleanup.warmUp()
    }

    private func trackHistoryWork(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        historyTasks[id] = Task { @MainActor in
            await work()
            self.historyTasks[id] = nil
        }
    }

    /// Der Rückgabewert endet erst nach allen notwendigen Verlaufs-Schreibvorgängen.
    /// Die App muss ihn vor dem geregelten Prozessende abwarten.
    @discardableResult
    public func shutdown() -> Task<Void, Never> {
        let retries = retryLock.withLock {
            shuttingDown = true
            let tasks = Array(retryTasks.values)
            tasks.forEach { $0.cancel() }
            return tasks
        }
        let processing = sessionTask
        cancel()
        serverManager.stop()
        return Task { @MainActor in
            await processing?.value
            for task in retries { _ = try? await task.value }
            // Import-Abbruch kann erst nach geschlossenem Decoder einen Löschrest
            // sichern. Auch diese nach dem ersten Await entstandene Arbeit abwarten.
            while !self.historyTasks.isEmpty {
                for task in Array(self.historyTasks.values) { await task.value }
            }
        }
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
        if state == .starting, newState != .starting { timingStore?.finishPreparation() }
        switch newState {
        case .starting, .recording, .paused, .resuming: break
        case .idle, .error, .processing:
            audioSession = nil
            clearTranscriptPreview()
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
        sessionRequest = requests.snapshot(appBundleID: requestAppBundleID?())
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
    private let onPreview: ((Int, DictationTranscriptPreview) -> Void)?
    private var completedSlots = Set<Int>()
    init(onPreview: ((Int, DictationTranscriptPreview) -> Void)? = nil) { self.onPreview = onPreview }
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
        completedSlots.insert(index)
        if let onPreview {
            var prefix: [String] = []
            for slot in slots.indices {
                guard completedSlots.contains(slot), let text = slots[slot] else { break }
                prefix.append(text)
            }
            let failed = completedSlots.contains { slots[$0] == nil }
            onPreview(completedCount, DictationTranscriptPreview(text: DictationEngine.joinSegments(prefix), hasFailedSegment: failed))
        }
        // Falls finish() schon wartet und wir das letzte offene Segment waren: aufwecken.
        if completedCount >= targetCount, let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    func completedTexts() -> [String] { slots.compactMap { $0 } }

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
