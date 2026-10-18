import Foundation

@MainActor public protocol AudioCapture: AnyObject {
    var onProgress: ((TimeInterval) -> Void)? { get set }
    var onStopped: ((TimeInterval, ClientFailure?) -> Void)? { get set }
    func start(at url: URL, maxDuration: TimeInterval) async throws
    func stop() -> TimeInterval
}

public struct MobileState: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, permission, recording, ready, sending, result, failed }
    public var phase: Phase = .idle
    public var recording: Recording?
    public var elapsed: TimeInterval = 0
    public var uploadProgress: Double = 0
    public var reply: DictationReply?
    public var failure: ClientFailure?
    public var recovered = false
    public init() {}
}

@MainActor public final class DictationSession {
    public private(set) var state = MobileState() { didSet { onChange?(state) } }
    public var onChange: ((MobileState) -> Void)?
    private let capture: any AudioCapture
    private let files: any RecordingFiles
    private let bridge: any BridgeAccess
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    public init(capture: any AudioCapture, files: any RecordingFiles, bridge: any BridgeAccess) {
        self.capture = capture; self.files = files; self.bridge = bridge
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

    public func record() {
        guard operation == nil, state.recording == nil, state.phase != .recording else { return }
        generation = UUID(); let current = generation
        state = MobileState(); state.phase = .permission
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
        guard operation == nil, let recording = state.recording, state.phase != .recording, state.reply == nil else { return }
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

    public func cancel() {
        let phase = state.phase
        generation = UUID(); operation?.cancel(); operation = nil
        if phase == .sending { state.phase = .ready; state.failure = nil; return }
        if phase == .recording || phase == .permission { _ = capture.stop(); state.phase = .ready; discard() }
    }

    public func interrupt() {
        if state.phase == .recording { finishCapture(duration: capture.stop(), failure: .interrupted) }
        else if state.phase == .permission { cancel() }
        else if state.phase == .sending { cancel(); state.failure = .interrupted }
    }

    public func discard() {
        guard operation == nil, state.phase != .recording else { return }
        do { try files.discard(); state = MobileState() }
        catch { state.phase = .failed; state.failure = .storageFailed }
    }
}
