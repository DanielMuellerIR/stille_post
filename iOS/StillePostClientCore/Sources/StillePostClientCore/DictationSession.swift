import Foundation

@MainActor public protocol AudioCapture: AnyObject {
    var onProgress: ((TimeInterval) -> Void)? { get set }
    var onStopped: ((TimeInterval, ClientFailure?) -> Void)? { get set }
    func start(at url: URL, maxDuration: TimeInterval) async throws
    func stop() -> TimeInterval
}

public struct MobileState: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, permission, recording, ready, sending, transcribing, stopping, cleaning, result, failed }
    public var phase: Phase = .idle
    public var recording: Recording?
    public var elapsed: TimeInterval = 0
    public var uploadProgress: Double = 0
    public var transcriptionProgress: Double = 0
    public var reply: DictationReply?
    public var failure: ClientFailure?
    public var modelFailure: LocalModelFailure?
    public var mode: DictationMode = .mac
    public var language: DictationLanguage = .de
    public var localText: String?
    public var recovered = false
    public init() {}
}

@MainActor public final class DictationSession {
    public private(set) var state = MobileState() { didSet { onChange?(state) } }
    public var onChange: ((MobileState) -> Void)?
    private let capture: any AudioCapture
    private let files: any RecordingFiles
    private let bridge: any BridgeAccess
    private let offline: (any OfflineDictating)?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var interruptionFailure: ClientFailure?

    public init(capture: any AudioCapture, files: any RecordingFiles, bridge: any BridgeAccess,
                offline: (any OfflineDictating)? = nil, mode: DictationMode = .mac, language: DictationLanguage = .de) {
        self.capture = capture; self.files = files; self.bridge = bridge
        self.offline = offline; state.mode = mode; state.language = language
        capture.onProgress = { [weak self] elapsed in
            guard self?.state.phase == .recording else { return }
            self?.state.elapsed = elapsed
        }
        capture.onStopped = { [weak self] duration, failure in self?.finishCapture(duration: duration, failure: failure) }
        do {
            if let recording = try files.existing() {
                state.recording = recording; state.phase = .ready; state.recovered = true
            }
        } catch { state.phase = .failed; state.failure = .storageFailed }
    }

    public func configure(mode: DictationMode, language: DictationLanguage) {
        guard operation == nil, state.phase != .recording else { return }
        state.mode = mode; state.language = language
    }

    private func reset() {
        let mode = state.mode, language = state.language
        state = MobileState(); state.mode = mode; state.language = language
    }

    public func record() {
        guard operation == nil, state.recording == nil, state.phase != .recording else { return }
        generation = UUID(); let current = generation
        reset(); state.phase = .permission
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try files.prepare()
                try await capture.start(at: url, maxDuration: BridgeClient.maxRecordingSeconds)
                guard generation == current else { return }
                state.phase = .recording; operation = nil
            } catch {
                guard generation == current else { return }
                operation = nil
                if error is CancellationError { return }
                state.recording = try? files.existing()
                state.phase = .failed; state.failure = error as? ClientFailure ?? .recordingFailed
            }
        }
    }

    public func stop() {
        guard state.phase == .recording else { return }
        finishCapture(duration: capture.stop(), failure: nil)
    }

    private func finishCapture(duration: TimeInterval, failure: ClientFailure?) {
        guard state.phase == .recording else { return }
        do {
            let recording = try files.finish(duration: duration)
            state.recording = recording; state.elapsed = duration; state.phase = failure == nil ? .ready : .failed
            state.failure = failure
        } catch {
            state.recording = try? files.existing(); state.phase = .failed
            state.failure = error as? ClientFailure ?? .storageFailed
        }
    }

    public func send(credentials: BridgeCredentials) {
        guard state.mode == .mac, operation == nil, let recording = state.recording, state.phase != .recording, state.reply == nil else { return }
        generation = UUID(); let current = generation
        state.phase = .sending; state.failure = nil; state.uploadProgress = 0; state.recovered = false
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await bridge.dictate(recording, credentials: credentials) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.state.phase == .sending else { return }
                        self.state.uploadProgress = progress
                    }
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                state.reply = reply
                try files.discard()
                state.recording = nil; state.phase = .result; operation = nil
            } catch {
                guard generation == current else { return }
                operation = nil
                state.phase = .failed; state.failure = error as? ClientFailure ?? .unavailable
            }
        }
    }

    public func transcribe() {
        guard state.mode == .offline, operation == nil, let recording = state.recording,
              state.phase != .recording, state.reply == nil else { return }
        generation = UUID(); let current = generation, language = state.language
        interruptionFailure = nil
        state.phase = .transcribing; state.failure = nil; state.modelFailure = nil; state.transcriptionProgress = 0
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { operation = nil } }
            do {
                guard let offline else { throw LocalModelFailure.missing }
                let text = try await offline.transcribe(recording, language: language) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.state.phase == .transcribing else { return }
                        self.state.transcriptionProgress = min(max(progress, 0), 1)
                    }
                }
                try Task.checkCancellation()
                guard generation == current else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure.noSpeech }
                state.reply = DictationReply(text: text, origin: "local"); state.localText = text
                try files.discard()
                state.recording = nil; state.phase = .result; state.recovered = false
            } catch is CancellationError {
                state.phase = .ready; state.failure = interruptionFailure
            } catch {
                state.phase = .failed
                if let failure = error as? LocalModelFailure { state.modelFailure = failure }
                else { state.failure = error as? ClientFailure ?? .recordingFailed }
            }
        }
    }

    public func cleanText(credentials: BridgeCredentials) {
        guard operation == nil, let text = state.localText, state.reply != nil, state.recording == nil else { return }
        generation = UUID(); let current = generation
        state.phase = .cleaning; state.failure = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { operation = nil } }
            do {
                let reply = try await bridge.cleanup(text, credentials: credentials)
                try Task.checkCancellation()
                guard generation == current else { return }
                state.reply = reply; state.phase = .result
            } catch is CancellationError { }
            catch {
                guard generation == current else { return }
                state.phase = .result; state.failure = error as? ClientFailure ?? .unavailable
            }
        }
    }

    public func cancel() {
        let phase = state.phase
        if phase == .transcribing || phase == .stopping {
            operation?.cancel(); state.phase = .stopping; return
        }
        generation = UUID(); operation?.cancel(); operation = nil
        if phase == .cleaning { state.phase = .result; state.failure = nil; return }
        if phase == .sending { state.phase = .ready; state.failure = nil; return }
        if phase == .recording || phase == .permission { _ = capture.stop(); state.phase = .ready; discard() }
    }

    public func interrupt(failure: ClientFailure = .interrupted) {
        if state.phase == .transcribing || state.phase == .stopping {
            interruptionFailure = failure; cancel(); return
        }
        if state.phase == .recording { finishCapture(duration: capture.stop(), failure: failure) }
        else if state.phase == .permission { cancel() }
        else if state.phase == .sending || state.phase == .cleaning { cancel(); state.failure = failure }
    }

    public func discard() {
        guard operation == nil, state.phase != .recording else { return }
        do { try files.discard(); reset() }
        catch { state.phase = .failed; state.failure = .storageFailed }
    }
}
