import Foundation
@testable import StillePostCore

// Zwei unveränderte AP17-Dateien durch Aufnahmephasen, Produkt-VAD, Whisper und
// genau eine Gesamtbereinigung. Das ist eine Datei-, keine Mikrofonabnahme.
@main struct SileroPipelineE2E {
    @MainActor static func main() async throws {
        let corpus = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        let language = CommandLine.arguments[4]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = try ["quiet", "terms"].map {
            try AudioDecoder.samples16kMono(from: Data(contentsOf: corpus.appendingPathComponent("audio/\(language)-\($0).wav")))
        }
        var config = Config()
        config.whisper.language = language
        config.whisper.autostart = false
        config.cleanup.localOnly = true
        config.vad.detector = .silero
        config.vad.autoStopAfterSilenceSec = 0
        config.ui.liveTranscriptPreview = true
        let cleanup = CountingCleanup(config: config.cleanup)
        var recorders: [FileRecorder] = [], result: DictationResult?, wav: URL?
        var selections: [Config.Vad.Detector] = []
        let engine = DictationEngine(config: config, history: HistoryStore(baseDir: root.appendingPathComponent("support")), dependencies: .init(
            transcriber: WhisperClient(config: config.whisper), server: WhisperServerManager(config: config.whisper), cleanup: cleanup,
            makeRecorder: { _ in let recorder = FileRecorder(); recorders.append(recorder); return recorder },
            makeSegmenter: { config in
                selections.append(config.detector)
                let segmenter = await VadSegmenter.prepared(config: config, modelDirectory: model)
                guard segmenter.fallbackReason == nil else { fatalError("Unerwarteter VAD-Rückfall") }
                return segmenter
            },
            makeWavWriter: { wav = $0; return try WavFileWriter(url: $0) }, requestMicrophoneAccess: { true }))
        engine.onResult = { result = $0 }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if condition() { return }
                if case .error(let message) = engine.state { throw Check.failed(message) }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw Check.failed("Timeout")
        }
        engine.start()
        try await wait { engine.state == .recording }
        for phase in 0..<2 {
            if phase == 1 {
                var changed = config; changed.vad.detector = .rms; changed.history.storeText = false
                engine.configure(changed)
                engine.resume(); try await wait { engine.state == .recording }
            }
            for offset in stride(from: 0, to: audio[phase].count, by: 320) {
                recorders[phase].onSamples?(Array(audio[phase][offset..<min(offset+320,audio[phase].count)]))
            }
            engine.pause()
            guard engine.state == .paused, cleanup.calls == 0 else { throw Check.failed("Pause/Cleanup") }
            if phase == 0 { try await wait { !(engine.transcriptPreview?.text ?? "").isEmpty } }
        }
        engine.stop()
        try await wait { result != nil }
        guard let entry = result?.entry, let wav, cleanup.calls == 1, cleanup.warmups == 1,
              selections == [.silero, .silero], !FileManager.default.fileExists(atPath: wav.path),
              abs(entry.durationSec-Double(audio.reduce(0) { $0+$1.count })/16000) < 0.001,
              entry.rawText.contains("PostgreSQL"),
              entry.rawText.lowercased().contains(language == "de" ? "keine" : "not"),
              entry.rawText.contains("12") || entry.rawText.lowercased().contains(language == "de" ? "zwölf" : "twelve") else {
            throw Check.failed("Gesamtergebnis/Dateilebenszyklus: \(result?.text ?? "")")
        }
        try JSONSerialization.data(withJSONObject: ["passed":true,"language":language,"raw":entry.rawText,"clean":entry.cleanText,
            "audioSeconds":entry.durationSec,"cleanupCalls":cleanup.calls,"warmups":cleanup.warmups,
            "wavDeleted":true,"selections":selections.map(\.rawValue)], options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("result.json"))
        await engine.shutdown().value
    }
    enum Check: Error { case failed(String) }
}
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
