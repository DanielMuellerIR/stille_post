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
        let retryMode = CommandLine.arguments.contains("--retry")
        let before = try digest(source)
        var raw = Config(); raw.whisper.autostart = false; raw.cleanup.localOnly = true
        var profile = Config.Profile(name: language.uppercased())
        profile.language = language
        if language == "en" { var policy = raw.history; policy.storeText = false; profile.history = policy }
        raw.profiles = [profile]; raw.selectedProfileID = profile.id
        let reviewed = raw.resolvedForRequest()
        let probe = ImportE2EProbe(failFirst: retryMode), cleanup = ImportE2ECleanup(config: reviewed.cleanup)
        let history = HistoryStore(baseDir: root.appendingPathComponent("support"))
        let engine = DictationEngine(config: raw, history: history, dependencies: .init(
            transcriber: ImportE2ETranscriber(config: reviewed.whisper, probe: probe),
            server: WhisperServerManager(config: reviewed.whisper), cleanup: cleanup,
            makeRecorder: { _ in probe.microphone(); return ImportE2ENoRecorder() },
            makeSegmenter: { VadSegmenter(config: $0) }, makeWavWriter: { try WavFileWriter(url: $0) },
            makeTranscriber: { ImportE2ETranscriber(config: $0, probe: probe) },
            requestMicrophoneAccess: { probe.microphone(); return false }))
        let session = AudioImportSession(engine: engine)
        var progress: [AudioImportProgress] = []
        engine.onAudioImportProgress = { progress.append($0); session.receiveProgress($0) }
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
        let entry: HistoryStore.Entry
        if retryMode {
            guard case .failed = session.state, cleanup.calls == 0,
                  let failed = try history.list().first, failed.audioIsComplete == true, failed.canRetry else {
                throw ImportE2EFailure.contract
            }
            engine.configure(raw)
            entry = try await engine.retry(entry: failed)
        } else {
            guard case .completed = session.state, let value = session.result?.entry else { throw ImportE2EFailure.contract }
            entry = value
        }
        guard entry.status == "ok", cleanup.calls == 1, cleanup.warmups == (retryMode ? 2 : 1), probe.languages.count >= 2,
              probe.languages.allSatisfy({ $0 == language }), probe.microphoneCalls == 0,
              try digest(source) == before, probe.maximumSamples <= 31 * 16000, probe.fileRequests == 0,
              try FileManager.default.contentsOfDirectory(at: history.recordingsDir, includingPropertiesForKeys: nil).isEmpty else {
            throw ImportE2EFailure.contract
        }
        let text = entry.rawText.lowercased()
        guard text.contains("server"), text.contains(language == "de" ? "wörterbuch" : "dictionary"),
              text.contains(language == "de" ? "nicht" : "not") else { throw ImportE2EFailure.content }
        if language == "en" { guard try history.list().isEmpty else { throw ImportE2EFailure.privacy } }
        let report: [String: Any] = ["passed":true,"language":language,"raw":entry.rawText,"clean":entry.cleanText,
            "rawFallback":entry.cleanupFellBack ?? false,"cleanupCalls":cleanup.calls,"warmups":cleanup.warmups,
            "transcriptionCount":probe.languages.count,"microphoneCalls":probe.microphoneCalls,
            "sourceSHA256":before.map { String(format:"%02x",$0) }.joined(),
            "maximumRequestSamples":probe.maximumSamples,"durationSeconds":entry.durationSec,
            "retry":retryMode,"syntheticFirstFailure":retryMode,"fileRequests":probe.fileRequests,
            "progressUpdates":progress.count,"progressReachedSeconds":progress.last?.audioSeconds ?? 0,
            "sourceUnchanged":true,"workingWavDeleted":true,"storesText":entry.storesText as Any? ?? NSNull()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("result.json"))
        session.close(); await engine.shutdown().value
        print("PASS Dateiimport mit realem VAD/Whisper/Cleanup: " + language + " / " + source.pathExtension)
    }
    static func digest(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            guard let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data); return true
        }) {}
        return hash.finalize()
    }
}
private enum ImportE2EFailure: Error { case contract, content, privacy, microphone, syntheticTranscription }
private final class ImportE2ENoRecorder: DictationRecorder {
    var onSamples: (([Float]) -> Void)?, onFailure: ((Error) -> Void)?
    func start() throws { throw ImportE2EFailure.microphone }
    func stop() {}
}
private final class ImportE2EProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = [], microphones = 0, largestSamples = 0, files = 0
    private let failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    var languages: [String] { lock.withLock { values } }
    var microphoneCalls: Int { lock.withLock { microphones } }
    var maximumSamples: Int { lock.withLock { largestSamples } }
    var fileRequests: Int { lock.withLock { files } }
    func requested(_ language: String, samples: Int, file: Bool = false) -> Bool {
        lock.withLock {
            values.append(language); largestSamples = max(largestSamples, samples)
            if file { files += 1 }
            return failFirst && values.count == 1
        }
    }
    func microphone() { lock.withLock { microphones += 1 } }
}
private final class ImportE2ETranscriber: DictationTranscriber {
    let client: WhisperClient
    let language: String
    let probe: ImportE2EProbe
    init(config: Config.Whisper, probe: ImportE2EProbe) { client = WhisperClient(config: config); language = config.language; self.probe = probe }
    func isReachable() async -> Bool { await client.isReachable() }
    func health() async -> WhisperClient.Health { await client.health() }
    func transcribe(samples: [Float]) async throws -> String {
        if probe.requested(language, samples: samples.count) { throw ImportE2EFailure.syntheticTranscription }
        return try await client.transcribe(samples: samples)
    }
    func transcribe(wavFile: URL) async throws -> String {
        if probe.requested(language, samples: 0, file: true) { throw ImportE2EFailure.syntheticTranscription }
        return try await client.transcribe(wavFile: wavFile)
    }
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
