import Foundation

/// Die App nutzt ihre vorhandene Engine, aber eine eigene Ausgabezuordnung.
/// Methoden und Engine-Callbacks gehören auf den Hauptthread.
public final class AudioImportSession {
    public enum State: Equatable {
        case ready, processing(AudioImportStage), cancelling, completed, silence, cancelled, failed(String)
    }
    public private(set) var state: State = .ready
    public private(set) var isActive = false
    public private(set) var ownsCurrentSession = false
    public private(set) var configuration: Config?
    public private(set) var result: DictationResult?
    public private(set) var progress: AudioImportProgress?
    public var onChange: (() -> Void)?
    public var onErrorWhileClosed: ((String) -> Void)?
    public var recordingsDirectory: URL { engine.history.recordingsDir }
    private let engine: DictationEngine
    private var cancelling = false
    private var closed = false

    public init(engine: DictationEngine) { self.engine = engine }
    public func owns(_ source: DictationEngine) -> Bool { ownsCurrentSession && engine === source }
    public func uses(_ source: DictationEngine) -> Bool { engine === source }

    public func start(file: URL, configuration reviewed: Config, currentConfiguration: Config,
                      nextRequestConfiguration: Config, allowed: Bool, beforeStart: () -> Bool = { true }) {
        guard !isActive else { return }
        guard allowed, !engine.hasInFlightRequests else { fail("test_dictation.busy"); return }
        guard reviewed == currentConfiguration else { fail("test_dictation.changed"); return }
        guard beforeStart() else { fail("test_dictation.busy"); return }
        configuration = reviewed.resolvedForRequest(); result = nil
        progress = nil
        cancelling = false; closed = false
        ownsCurrentSession = true; isActive = true; state = .processing(.decoding)
        onChange?()
        engine.configure(configuration!)
        engine.importAudioFile(file)
        engine.configure(nextRequestConfiguration)
        if isActive, !engine.hasInFlightRequests { fail("audio_import.cannot_start") }
    }

    public func receiveState(_ value: DictationState) {
        guard ownsCurrentSession else { return }
        switch value {
        case .error(let message):
            progress = nil
            state = .failed(message); isActive = false
            if closed { onErrorWhileClosed?(message) }
        case .idle where cancelling:
            progress = nil
            state = .cancelled; isActive = false
        default: break
        }
        if closed, !isActive { configuration = nil; result = nil }
        onChange?()
    }
    public func receiveStage(_ stage: AudioImportStage) {
        guard ownsCurrentSession, isActive, !cancelling else { return }
        progress = nil; state = .processing(stage); onChange?()
    }
    public func receiveProgress(_ value: AudioImportProgress) {
        guard ownsCurrentSession, isActive, !cancelling, state == .processing(value.stage) else { return }
        progress = value; onChange?()
    }
    public func receiveResult(_ value: DictationResult) {
        guard ownsCurrentSession else { return }
        isActive = false
        progress = nil
        if value.entry?.isFailed == true {
            if !closed { result = value }
            state = .failed(value.entry?.errorMessage ?? L10n.text("audio_import.failed"))
        } else if value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = nil; state = .silence
        } else {
            if !closed { result = value }
            state = .completed
        }
        if closed { configuration = nil; result = nil }
        onChange?()
    }
    public func cancel() {
        guard isActive, ownsCurrentSession, !cancelling else { return }
        cancelling = true; result = nil; progress = nil; state = .cancelling
        onChange?(); engine.cancel()
    }
    public func reset() {
        guard !isActive else { return }
        closed = false; cancelling = false; result = nil; progress = nil; configuration = nil; state = .ready
        onChange?()
    }
    public func close() {
        closed = true; result = nil
        if isActive { cancel() }
        else { configuration = nil; state = .ready; onChange?() }
        // Die Zuordnung bleibt für späte Speicherfehler bestehen. Nur ein
        // tatsächlicher neuer Auftrag darf sie freigeben.
    }
    @discardableResult public func releaseForRegularStart() -> Bool {
        guard !isActive else { return false }
        ownsCurrentSession = false
        return true
    }
    private func fail(_ key: String) {
        state = .failed(L10n.text(key)); isActive = false; result = nil; onChange?()
    }
}
