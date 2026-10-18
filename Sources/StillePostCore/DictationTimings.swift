import Foundation

public struct DictationPhaseTimings: Equatable, Sendable {
    public let preparationSec: TimeInterval?
    public let recordingSec: TimeInterval?
    public let transcriptionSec: TimeInterval
    public let cleanupSec: TimeInterval?
    public let transcriptionCount: Int
    public static let empty = Self(preparationSec: nil, recordingSec: nil, transcriptionSec: 0, cleanupSec: nil, transcriptionCount: 0)
}

/// Jeder Auftrag besitzt einen eigenen Speicher. Späte Segmenttasks erfassen
/// diesen Wert direkt und können damit keine neue Aufnahmezeit verändern.
final class DictationTimingStore {
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private let started: TimeInterval
    private var preparation: TimeInterval?
    private var recording: TimeInterval?
    private var transcription: TimeInterval = 0
    private var cleanup: TimeInterval?
    private var count = 0
    init(clock: @escaping () -> TimeInterval) { self.clock = clock; started = clock() }
    func finishPreparation() {
        lock.withLock { if preparation == nil { preparation = max(0, clock() - started) } }
    }
    func finishRecording(seconds: TimeInterval) {
        lock.withLock { if recording == nil { recording = max(0, seconds) } }
    }
    func addTranscription(seconds: TimeInterval) {
        lock.withLock { transcription += max(0, seconds); count += 1 }
    }
    func finishCleanup(seconds: TimeInterval) { lock.withLock { cleanup = max(0, seconds) } }
    var snapshot: DictationPhaseTimings {
        lock.withLock { .init(preparationSec: preparation, recordingSec: recording, transcriptionSec: transcription, cleanupSec: cleanup, transcriptionCount: count) }
    }
}
