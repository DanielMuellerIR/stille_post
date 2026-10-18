import Foundation
import CryptoKit
@testable import StillePostCore

// Echte Datei-/VAD-/Whisper-/Cleanup-Pipeline mit ausdrücklich künstlichem Audio.
// Ohne Mikrofon, GUI oder Clipboard; Zusammenfassung nur für lokale Prüfbelege.
@main struct AudioImportE2E {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let language = CommandLine.arguments[2]
        let source = URL(fileURLWithPath: CommandLine.arguments[3])
        let before = try Data(contentsOf: source)
        var raw = Config(); raw.whisper.autostart = false; raw.cleanup.localOnly = true
        var profile = Config.Profile(name: language.uppercased())
        profile.language = language
        if language == "en" { var policy = raw.history; policy.storeText = false; profile.history = policy }
        raw.profiles = [profile]; raw.selectedProfileID = profile.id
        let reviewed = raw.resolvedForRequest()
        let probe = ImportE2EProbe(), cleanup = ImportE2ECleanup(config: reviewed.cleanup)
        let history = HistoryStore(baseDir: root.appendingPathComponent("support"))
        let engine = DictationEngine(config: raw, history: history, dependencies: .init(
            transcriber: ImportE2ETranscriber(config: reviewed.whisper, probe: probe),
            server: WhisperServerManager(config: reviewed.whisper), cleanup: cleanup,
            makeRecorder: { _ in probe.microphone(); return ImportE2ENoRecorder() },
            makeSegmenter: { VadSegmenter(config: $0) }, makeWavWriter: { try WavFileWriter(url: $0) },
            makeTranscriber: { ImportE2ETranscriber(config: $0, probe: probe) },
            requestMicrophoneAccess: { probe.microphone(); return false }))
        let session = AudioImportSession(engine: engine)
        engine.onStateChange = { session.receiveState($0) }
        engine.onResult = { session.receiveResult($0) }
        engine.onAudioImportStage = { stage in
            session.receiveStage(stage)
            if stage == .transcribing {
                var changed = raw; changed.removeProfile(id: profile.id)
                changed.whisper.language = language == "de" ? "en" : "de"
                changed.history.storeText = true
                engine.configure(changed)
            }
        }
        session.start(file: source, configuration: reviewed, currentConfiguration: reviewed,
                      nextRequestConfiguration: raw, allowed: true)
        for _ in 0..<1800 {
            if !session.isActive && !engine.hasInFlightRequests { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .completed = session.state, let result = session.result, let entry = result.entry,
              cleanup.calls == 1, cleanup.warmups == 1, probe.languages.count >= 2,
              probe.languages.allSatisfy({ $0 == language }), probe.microphoneCalls == 0,
              try Data(contentsOf: source) == before,
              try FileManager.default.contentsOfDirectory(at: history.recordingsDir, includingPropertiesForKeys: nil).isEmpty else {
            throw ImportE2EFailure.contract
        }
        let text = entry.rawText.lowercased()
        guard text.contains("server"), text.contains(language == "de" ? "wörterbuch" : "dictionary"),
              text.contains(language == "de" ? "nicht" : "not") else { throw ImportE2EFailure.content }
        if language == "en" { guard try history.list().isEmpty else { throw ImportE2EFailure.privacy } }
        let report: [String: Any] = ["passed":true,"language":language,"raw":entry.rawText,"clean":result.text,
            "rawFallback":entry.cleanupFellBack ?? false,"cleanupCalls":cleanup.calls,"warmups":cleanup.warmups,
            "transcriptionCount":probe.languages.count,"microphoneCalls":probe.microphoneCalls,
            "sourceSHA256":SHA256.hash(data: before).map { String(format:"%02x",$0) }.joined(),
            "sourceUnchanged":true,"workingWavDeleted":true,"storesText":entry.storesText as Any? ?? NSNull()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        session.close(); await engine.shutdown().value
        print("PASS Dateiimport mit realem VAD/Whisper/Cleanup: " + language + " / " + source.pathExtension)
    }
}
private enum ImportE2EFailure: Error { case contract, content, privacy, microphone }
private final class ImportE2ENoRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    func start() throws { throw ImportE2EFailure.microphone }
    func stop() {}
}
private final class ImportE2EProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = [], microphones = 0
    var languages: [String] { lock.withLock { values } }
    var microphoneCalls: Int { lock.withLock { microphones } }
    func requested(_ language: String) { lock.withLock { values.append(language) } }
    func microphone() { lock.withLock { microphones += 1 } }
}
private final class ImportE2ETranscriber: DictationTranscriber {
    let client: WhisperClient
    let language: String
    let probe: ImportE2EProbe
    init(config: Config.Whisper, probe: ImportE2EProbe) { client = WhisperClient(config: config); language = config.language; self.probe = probe }
    func isReachable() async -> Bool { await client.isReachable() }
    func health() async -> WhisperClient.Health { await client.health() }
    func transcribe(samples: [Float]) async throws -> String { probe.requested(language); return try await client.transcribe(samples: samples) }
    func transcribe(wavFile: URL) async throws -> String { probe.requested(language); return try await client.transcribe(wavFile: wavFile) }
}
private final class ImportE2ECleanup: DictationCleanup {
    private let service: CleanupService
    private let lock = NSLock()
    private var total = 0, warmed = 0
    var calls: Int { lock.withLock { total } }
    var warmups: Int { lock.withLock { warmed } }
    var onFallbackEndpoint: ((String) -> Void)?, onPrimaryRetry: (() -> Void)?
    init(config: Config.Cleanup) { service = CleanupService(config: config) }
    func warmUp() { lock.withLock { warmed += 1 }; service.warmUp() }
    func clean(_ rawText: String) async -> CleanupService.Result { lock.withLock { total += 1 }; return await service.clean(rawText) }
}
