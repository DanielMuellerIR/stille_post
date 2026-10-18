#if DEBUG && targetEnvironment(simulator)
import Foundation
import StillePostClientCore

// Prüft native Ansichten und den Versand mit künstlichem AAC. Auf echten
// Geräten ist dieser Ersatz nicht kompiliert und ersetzt keine Mikrofonabnahme.
@MainActor final class SimulatorAudioCapture: AudioCapture {
    var onProgress: ((TimeInterval) -> Void)?
    var onStopped: ((TimeInterval, ClientFailure?) -> Void)?
    private var started: Date?
    private var timer: Timer?
    func start(at url: URL, maxDuration: TimeInterval) async throws {
        try Task.checkCancellation()
        let source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("development-audio.m4a")
        try FileManager.default.copyItem(at: source, to: url)
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.started else { return }
                let elapsed = Date().timeIntervalSince(started)
                self.onProgress?(elapsed)
                if elapsed >= maxDuration { self.onStopped?(self.stop(), nil) }
            }
        }
    }
    func stop() -> TimeInterval {
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        started = nil; timer?.invalidate(); timer = nil
        return elapsed
    }
}
#endif
