import Foundation
@testable import StillePostCore

// Produktiver Testauftrag mit lokalen Sprachdateien statt Mikrofon und echten
// lokalen Whisper-/Bereinigungsdiensten. Keine Ausgabe und kein Clipboard.
@main struct TestDictationAudioE2E {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let mode = CommandLine.arguments[2]
        let first = try AudioDecoder.samples16kMono(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
        let second = try AudioDecoder.samples16kMono(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4])))
        var raw = Config()
        raw.ui.liveTranscriptPreview = CommandLine.arguments.dropFirst(5).contains("preview")
        raw.whisper.autostart = false
        raw.cleanup.localOnly = true
        var profile = Config.Profile(name: mode == "tech" ? "Technik" : mode.uppercased())
        profile.language = mode == "en" ? "en" : "de"
        if mode == "en" { var policy = raw.history; policy.storeText = false; profile.history = policy }
        if mode == "tech" {
            profile.vocabulary = Config.Vocabulary(try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: raw.cleanup))
        }
        raw.profiles = [profile]; raw.selectedProfileID = profile.id
        let config = raw.resolvedForRequest()
        let cleanup = AudioCleanupSpy(config: config.cleanup)
        var recorder: FileTestRecorder?, wav: URL?
        let history = HistoryStore(baseDir: root.appendingPathComponent("support"))
        let engine = DictationEngine(config: raw, history: history, dependencies: .init(
            transcriber: WhisperClient(config: config.whisper), server: WhisperServerManager(config: config.whisper),
            cleanup: cleanup, makeRecorder: { _ in let value = FileTestRecorder(); recorder = value; return value },
            makeSegmenter: { VadSegmenter(config: $0) },
            makeWavWriter: { wav = $0; return try WavFileWriter(url: $0) }, requestMicrophoneAccess: { true }))
        let session = TestDictationSession(engine: engine)
        engine.onStateChange = { session.receiveState($0) }
        engine.onResult = { session.receiveResult($0) }
        var previewUpdates = 0
        engine.onTranscriptPreview = { if $0?.text.isEmpty == false { previewUpdates += 1 } }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1800 {
                if condition() { return }
                if case .failed = session.state { throw AudioTestFailure.failed }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw AudioTestFailure.timeout
        }
        session.start(configuration: config, currentConfiguration: config,
                      nextRequestConfiguration: raw, inputAvailable: true, allowed: true)
        try await wait { session.state == .recording }
        let audio = first + Array(repeating: Float.zero, count: 16_000) + second
        for offset in stride(from: 0, to: audio.count, by: 320) {
            recorder?.onSamples?(Array(audio[offset..<min(offset+320,audio.count)]))
        }
        if raw.ui.liveTranscriptPreview {
            try await wait { engine.transcriptPreview?.text.isEmpty == false }
            guard cleanup.calls == 0 else { throw AudioTestFailure.failed }
        }
        var changed = raw; changed.removeProfile(id: profile.id); changed.history.storeText = !config.history.storeText
        changed.whisper.language = mode == "en" ? "de" : "en"
        engine.configure(changed)
        session.stop()
        try await wait { session.state == .completed }
        guard let result = session.result, let entry = result.entry, let wav,
              cleanup.calls == 1, cleanup.warmups == 1, session.timings.transcriptionCount >= 2,
              session.timings.preparationSec != nil, session.timings.cleanupSec != nil,
              abs(session.audioDuration-Double(audio.count)/16000)<0.001,
              !FileManager.default.fileExists(atPath: wav.path),
              session.configuration?.whisper.language == profile.language else { throw AudioTestFailure.failed }
        guard engine.transcriptPreview == nil else { throw AudioTestFailure.failed }
        let text = entry.rawText.lowercased()
        guard text.contains(mode == "tech" ? "whisper" : "server"),
              text.contains(mode == "en" ? "dictionary" : "wörterbuch"),
              text.contains(mode == "en" ? "not" : "nicht") else { throw AudioTestFailure.content }
        if mode == "tech" {
            guard text.contains("128"), text.contains("256"), (text.contains("1.2") || text.contains("1,2")) else { throw AudioTestFailure.content }
        }
        if mode == "en" { guard try history.list().isEmpty else { throw AudioTestFailure.privacy } }
        let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        try session.exportReport(version: version).write(to: root.appendingPathComponent("phase-report.txt"), atomically: true, encoding: .utf8)
        let report: [String: Any] = ["passed":true,"mode":mode,"raw":entry.rawText,"clean":result.text,
            "rawFallback":entry.cleanupFellBack ?? false,"fallbackReason":entry.cleanupFallbackReason as Any? ?? NSNull(),
            "audioSec":session.audioDuration,"transcriptionCount":session.timings.transcriptionCount,
            "cleanupCalls":cleanup.calls,"warmups":cleanup.warmups,"wavDeleted":true,
            "previewUpdates":previewUpdates,
            "frozenLanguage":session.configuration?.whisper.language ?? "unknown",
            "storesText":entry.storesText as Any? ?? NSNull()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        session.close(); await engine.shutdown().value
        print("PASS Testdiktat mit realem VAD/Whisper/Cleanup: " + mode)
    }
}
private enum AudioTestFailure: Error { case failed, timeout, content, privacy }
private final class FileTestRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    func start() throws {}
    func stop() {}
}
private final class AudioCleanupSpy: DictationCleanup {
    private let service: CleanupService
    private let lock = NSLock()
    private var callCount = 0, warmCount = 0
    var calls: Int { lock.withLock { callCount } }
    var warmups: Int { lock.withLock { warmCount } }
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    init(config: Config.Cleanup) { service = CleanupService(config: config) }
    func warmUp() { lock.withLock { warmCount += 1 }; service.warmUp() }
    func clean(_ rawText: String) async -> CleanupService.Result { lock.withLock { callCount += 1 }; return await service.clean(rawText) }
}
