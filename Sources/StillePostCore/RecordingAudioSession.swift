import Foundation

/// Schließt eine Aufnahmephase erst, wenn ihr letzter Sample-Callback fertig ist.
/// Späte Taps einer alten Phase dürfen weder die WAV noch den neuen VAD erreichen.
final class RecordingAudioSession {
    private let lock = NSLock()
    private var phase: UUID?
    private var acceptingSamples = false
    private var sampleCount: UInt64 = 0

    var duration: TimeInterval {
        lock.withLock { Double(sampleCount) / Double(WavCodec.sampleRate) }
    }

    func beginPhase(acceptingSamples: Bool) -> UUID {
        lock.withLock {
            let id = UUID()
            phase = id
            self.acceptingSamples = acceptingSamples
            return id
        }
    }

    func acceptSamples(in id: UUID) {
        lock.withLock {
            if phase == id { acceptingSamples = true }
        }
    }

    func consume(_ samples: [Float], in id: UUID, _ work: () -> Void) {
        lock.withLock {
            guard phase == id, acceptingSamples else { return }
            sampleCount += UInt64(samples.count)
            work()
        }
    }

    func closePhase() {
        lock.withLock {
            acceptingSamples = false
            phase = nil
        }
    }
}
