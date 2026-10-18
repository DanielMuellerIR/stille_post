import AppKit
@testable import StillePostCore

// Produktiver Core und Overlay mit künstlichen Audioquellen: kein Mikrofon,
// Netz oder Einfügen. Der Runner bedient die echten nicht aktivierenden Buttons.
@main struct RecordingControlsRegression {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let scenario = CommandLine.arguments[2]
        let history = HistoryStore(baseDir: root.appendingPathComponent("support"))
        var config = Config()
        config.whisper.language = "de"
        config.ui.overlayPosition = "bottomCenter"
        config.ui.sounds = false
        let cleanup = ControlsCleanup(), server = ControlsServer()
        var recorders: [ControlsRecorder] = []
        var results = 0, wav: URL?, events: [String] = []
        let overlay = OverlayController(config: config.ui)
        overlay.recordingContext = "Technik · Deutsch"
        overlay.recordingReason = "Manuelle Auswahl"
        let engine = DictationEngine(config: config, history: history, dependencies: .init(
            transcriber: ControlsTranscriber(), server: server, cleanup: cleanup,
            makeRecorder: { _ in
                let recorder = ControlsRecorder(number: recorders.count + 1)
                recorder.fail = scenario == "failure" && !recorders.isEmpty
                recorders.append(recorder)
                return recorder
            }, makeSegmenter: { _ in ControlsSegmenter() },
            makeWavWriter: { url in wav = url; return try WavFileWriter(url: url) },
            requestMicrophoneAccess: { true }))
        engine.onBeforeRecordingStart = {
            if scenario == "delay" && !recorders.isEmpty { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        overlay.levelProvider = { (engine.currentLevelDb, engine.recordingDuration) }
        overlay.onPauseResume = {
            if engine.state == .recording { engine.pause() }
            else if engine.state == .paused { engine.resume() }
        }
        overlay.onClickStop = { engine.stop() }
        engine.onStateChange = { state in
            events.append(String(describing: state))
            switch state {
            case .starting: overlay.show(.starting(hold: false))
            case .resuming: overlay.show(.starting(hold: false, resuming: true))
            case .recording: overlay.show(.recording)
            case .paused: overlay.show(.paused)
            case .processing: overlay.show(.processing())
            case .error(let message): overlay.show(.failure(message))
            case .idle: overlay.hide()
            }
        }
        engine.onResult = { _ in results += 1 }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let entries = (try? history.list()) ?? []
                let value: [String: Any] = ["state": String(describing: engine.state), "events": events,
                    "audioSeconds": engine.recordingDuration, "samples": recorders.map(\.samples),
                    "stops": recorders.map(\.stops), "recorders": recorders.count,
                    "cleanupCalls": cleanup.inputs.count, "warmups": cleanup.warmups,
                    "cleanupInputs": cleanup.inputs, "results": results,
                    "history": entries.map { ["raw": $0.rawText, "status": $0.status, "duration": $0.durationSec] as [String: Any] },
                    "wavExists": wav.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                    "wavBytes": wav.flatMap { try? Data(contentsOf: $0).count } ?? 0,
                    "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
                try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("state.json"), options: .atomic)
            }
        }
        engine.start()
        withExtendedLifetime((engine, overlay)) { app.run() }
    }
}
private enum ControlsError: Error { case device }
private final class ControlsRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    let number: Int
    var timer: Timer?, samples = 0, stops = 0, fail = false
    init(number: Int) { self.number = number }
    func start() throws {
        if fail { throw ControlsError.device }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.samples += 800
            self.onSamples?(Array(repeating: Float(self.number) / 10, count: 800))
        }
    }
    func stop() { timer?.invalidate(); timer = nil; stops += 1 }
}
private final class ControlsSegmenter: DictationSegmenter {
    var onSegment: ((VadSegmenter.Segment) -> Void)?, onAutoStop: (() -> Void)?
    var currentLevelDb: Double { -20 }
    var samples: [Float] = []
    func process(_ samples: [Float]) { self.samples += samples }
    func flush() {
        guard !samples.isEmpty else { return }
        onSegment?(.init(samples: samples, hadSpeech: true, reason: .flush))
        samples = []
    }
}
private final class ControlsServer: DictationServer {
    func ensureRunning(reachability: any DictationTranscriber) async throws {}
    func stop() {}
}
private final class ControlsTranscriber: DictationTranscriber {
    func transcribe(samples: [Float]) async throws -> String { "Phase \(Int((Double(samples.first ?? 0) * 10).rounded()))." }
    func transcribe(wavFile: URL) async throws -> String { "Datei." }
    func isReachable() async -> Bool { true }
}
private final class ControlsCleanup: DictationCleanup {
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    var inputs: [String] = [], warmups = 0
    func warmUp() { warmups += 1 }
    func clean(_ rawText: String) async -> CleanupService.Result {
        inputs.append(rawText)
        return .init(text: rawText, usedFallback: false, fallbackReason: nil, endpoint: nil)
    }
}
