import Foundation
@testable import StillePostCore

// Zwei künstliche Sprachdateien durch den produktiven VAD, Whisper und Cleanup.
// Kein Mikrofon und kein Einfügen; Netzwerk bleibt auf lokalen Textdiensten.
@main struct PauseAudioE2E {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let language = CommandLine.arguments[2]
        let audio = try ["first.aiff", "second.aiff"].map {
            try AudioDecoder.samples16kMono(from: Data(contentsOf: root.appendingPathComponent($0)))
        }
        var config = Config()
        config.whisper.language = language
        config.whisper.autostart = false
        config.cleanup.localOnly = true
        config.vad.splitAfterSilenceSec = 60
        config.vad.maxSegmentSec = 60
        config.vad.autoStopAfterSilenceSec = 60
        let cleanup = CountingCleanup(config: config.cleanup)
        var recorders: [FileRecorder] = [], result: DictationResult?, wav: URL?
        let engine = DictationEngine(config: config, history: HistoryStore(baseDir: root.appendingPathComponent("support")), dependencies: .init(
            transcriber: WhisperClient(config: config.whisper), server: WhisperServerManager(config: config.whisper), cleanup: cleanup,
            makeRecorder: { _ in let value = FileRecorder(); recorders.append(value); return value },
            makeSegmenter: { VadSegmenter(config: $0) },
            makeWavWriter: { wav = $0; return try WavFileWriter(url: $0) }, requestMicrophoneAccess: { true }))
        engine.onResult = { result = $0 }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1800 {
                if condition() { return }
                if case .error = engine.state { throw FixtureError.failed }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw FixtureError.timeout
        }
        engine.start()
        try await wait { engine.state == .recording }
        for phase in 0..<2 {
            if phase == 1 {
                var changed = config; changed.whisper.language = language == "de" ? "en" : "de"
                changed.history.storeText = false; engine.configure(changed)
                engine.resume(); try await wait { engine.state == .recording }
            }
            for offset in stride(from: 0, to: audio[phase].count, by: 320) {
                recorders[phase].onSamples?(Array(audio[phase][offset..<min(offset+320,audio[phase].count)]))
            }
            engine.pause()
            guard engine.state == .paused, cleanup.calls == 0 else { throw FixtureError.failed }
            let duration = engine.recordingDuration
            try await Task.sleep(nanoseconds: 300_000_000)
            guard duration == engine.recordingDuration else { throw FixtureError.failed }
        }
        engine.stop()
        try await wait { result != nil }
        guard let entry = result?.entry, let wav, cleanup.calls == 1, cleanup.warmups == 1,
              !FileManager.default.fileExists(atPath: wav.path),
              abs(entry.durationSec - Double(audio.reduce(0) { $0 + $1.count }) / 16000) < 0.001,
              !entry.rawText.isEmpty, !entry.cleanText.isEmpty,
              entry.rawText.lowercased().contains(language == "de" ? "server" : "server"),
              entry.rawText.lowercased().contains(language == "de" ? "wörterbuch" : "dictionary") else { throw FixtureError.failed }
        let report: [String: Any] = ["passed":true,"language":language,"raw":entry.rawText,"clean":entry.cleanText,
            "audioSeconds":entry.durationSec,"phaseSamples":audio.map(\.count),"cleanupCalls":cleanup.calls,
            "warmups":cleanup.warmups,"cleanupFellBack":entry.cleanupFellBack ?? false,
            "wavDeleted":true,"frozenLanguage":engine.sessionConfiguration.whisper.language]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        await engine.shutdown().value
    }
}
private enum FixtureError: Error { case failed, timeout }
private final class FileRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    func start() throws {}
    func stop() {}
}
private final class CountingCleanup: DictationCleanup {
    let service: CleanupService
    var calls = 0, warmups = 0
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    init(config: Config.Cleanup) { service = CleanupService(config: config) }
    func warmUp() { warmups += 1; service.warmUp() }
    func clean(_ rawText: String) async -> CleanupService.Result { calls += 1; return await service.clean(rawText) }
}
