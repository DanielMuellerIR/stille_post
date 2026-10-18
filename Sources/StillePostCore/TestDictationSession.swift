import Foundation

/// Orchestriert einen ausdrücklichen Test auf der vorhandenen App-Engine.
/// Alle Methoden/Callbacks werden auf dem Hauptthread aufgerufen.
public final class TestDictationSession {
    public enum State: Equatable { case ready, preparing, recording, paused, processing, completed, silence, cancelled, failed(String) }
    public private(set) var state: State = .ready
    public private(set) var isActive = false
    public private(set) var ownsCurrentSession = false
    public private(set) var configuration: Config?
    public private(set) var result: DictationResult?
    public private(set) var timings: DictationPhaseTimings = .empty
    public private(set) var audioDuration: TimeInterval = 0
    public private(set) var levelDb: Double = -120
    public var onChange: (() -> Void)?
    public var recordingsDirectory: URL { engine.history.recordingsDir }
    private let engine: DictationEngine
    private let maximumDuration: TimeInterval
    private let clock: () -> TimeInterval
    private var recordingBegan: TimeInterval?
    private var timer: Timer?
    private var cancelling = false
    private var attemptedAt: Date?

    public convenience init(engine: DictationEngine, maximumRecordingDuration: TimeInterval = 20) {
        self.init(engine: engine, maximumRecordingDuration: maximumRecordingDuration,
                  clock: { ProcessInfo.processInfo.systemUptime })
    }
    init(engine: DictationEngine, maximumRecordingDuration: TimeInterval, clock: @escaping () -> TimeInterval) {
        self.engine = engine
        self.maximumDuration = max(0.01, min(20, maximumRecordingDuration))
        self.clock = clock
    }
    deinit { timer?.invalidate() }
    public func owns(_ source: DictationEngine) -> Bool { ownsCurrentSession && engine === source }
    public func uses(_ source: DictationEngine) -> Bool { engine === source }

    public func start(configuration reviewed: Config, currentConfiguration: Config,
                      nextRequestConfiguration: Config, inputAvailable: Bool, allowed: Bool) {
        guard !isActive else { return }
        attemptedAt = Date()
        guard allowed, !engine.hasInFlightRequests else { fail("test_dictation.busy"); return }
        guard reviewed == currentConfiguration else { fail("test_dictation.changed"); return }
        guard inputAvailable else { fail("test_dictation.no_input"); return }
        configuration = reviewed.resolvedForRequest()
        result = nil; timings = .empty; audioDuration = 0; levelDb = -120
        cancelling = false; recordingBegan = nil
        ownsCurrentSession = true; isActive = true; state = .preparing
        onChange?()
        engine.configure(configuration!)
        engine.start()
        // start() hat bereits einen eigenen Snapshot. Die globale Auswahl gilt
        // sofort wieder für kommende Aufträge, ohne den Test zu verändern.
        engine.configure(nextRequestConfiguration)
        if isActive, engine.state == .idle { fail("test_dictation.cannot_start") }
    }

    public func receiveState(_ value: DictationState) {
        guard ownsCurrentSession else { return }
        captureTimings()
        switch value {
        case .starting, .resuming: state = .preparing
        case .recording:
            state = .recording
            if recordingBegan == nil { recordingBegan = clock() }
            startTimer()
        case .paused: state = .paused
        case .processing: state = .processing; stopTimer()
        case .error(let message): state = .failed(message); isActive = false; stopTimer()
        case .idle:
            if cancelling { state = .cancelled; isActive = false; stopTimer() }
            // Der Ergebnis-Callback folgt im selben Hauptthread-Schritt.
        }
        onChange?()
    }
    public func receiveResult(_ value: DictationResult) {
        guard ownsCurrentSession else { return }
        captureTimings(); stopTimer(); isActive = false
        if let entry = value.entry, entry.isFailed {
            result = nil; state = .failed(entry.errorMessage ?? L10n.text("test_dictation.failed"))
        } else if value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = nil; state = .silence
        } else {
            result = value; state = .completed
            if let duration = value.entry?.durationSec { audioDuration = duration }
        }
        onChange?()
    }
    public func stop() {
        guard isActive, ownsCurrentSession else { return }
        if engine.state == .starting { cancel() }
        else { engine.stop() }
    }
    public func cancel() {
        guard isActive, ownsCurrentSession else { return }
        cancelling = true; result = nil; stopTimer()
        engine.cancel()
        captureTimings()
        if case .error = engine.state {} else { state = .cancelled; isActive = false }
        onChange?()
    }
    /// Nur abgeschlossene Testzuordnung freigeben, niemals einen aktiven Test
    /// durch einen regulären Start verdrängen.
    @discardableResult public func releaseForRegularStart() -> Bool {
        guard !isActive else { return false }
        ownsCurrentSession = false
        return true
    }
    public func reset() {
        guard !isActive else { return }
        ownsCurrentSession = false; result = nil; timings = .empty; audioDuration = 0
        configuration = nil; state = .ready; cancelling = false; attemptedAt = nil
        onChange?()
    }
    @discardableResult public func close() -> String? {
        let wasActive = isActive
        if isActive { cancel() }
        let error: String?
        if wasActive, case .failed(let message) = state { error = message } else { error = nil }
        stopTimer(); reset()
        return error
    }
    func pulse() {
        guard isActive, ownsCurrentSession else { return }
        captureTimings()
        levelDb = engine.currentLevelDb
        if engine.state == .recording { audioDuration = engine.recordingDuration }
        if let began = recordingBegan, clock() - began >= maximumDuration,
           engine.state == .recording || engine.state == .paused || engine.state == .resuming {
            stop()
        }
        onChange?()
    }
    /// Nur feste Codes, Zeiten und Datenschutzflags; weder Text noch Fehler,
    /// Profilnamen, Geräte, Adressen oder Dateipfade gelangen in diesen Bericht.
    public func exportReport(version: String) -> String {
        let header = DiagnosticReport(date: attemptedAt ?? Date(), findings: []).export(version: version)
        let code: String
        switch state {
        case .ready: code = "ready"
        case .preparing: code = "preparing"
        case .recording: code = "recording"
        case .paused: code = "paused"
        case .processing: code = "processing"
        case .completed: code = "completed"
        case .silence: code = "silence"
        case .cancelled: code = "cancelled"
        case .failed: code = "failed"
        }
        func number(_ value: TimeInterval?) -> String {
            value.map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "unknown"
        }
        let origin = result == nil ? "none" : (result?.entry?.cleanupFellBack == true ? "raw_fallback" :
            (configuration?.cleanup.enabled == false ? "cleanup_disabled" : "cleanup"))
        return ([header, "test.state=" + code, "test.source=" + origin,
            "test.preparation_sec=" + number(timings.preparationSec),
            "test.recording_sec=" + number(timings.recordingSec),
            "test.transcription_sum_sec=" + number(timings.transcriptionSec),
            "test.transcription_count=\(timings.transcriptionCount)",
            "test.cleanup_sec=" + number(timings.cleanupSec),
            "test.local_only=" + (configuration.map { String($0.cleanup.localOnly) } ?? "unknown"),
            "test.stores_text=" + (configuration.map { String($0.history.storeText) } ?? "unknown")]).joined(separator: "\n")
    }

    private func captureTimings() {
        timings = engine.phaseTimings
        if let recorded = timings.recordingSec { audioDuration = recorded }
    }
    private func fail(_ key: String) {
        result = nil; timings = .empty; audioDuration = 0; stopTimer()
        state = .failed(L10n.text(key)); isActive = false; onChange?()
    }
    private func startTimer() {
        guard timer == nil else { return }
        let value = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pulse() }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
}
