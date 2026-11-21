import Foundation

/// Kleine interne Grenzen für den zustandsreichen Diktat-Lifecycle. Produktiv
/// stehen dahinter unverändert die bestehenden Klassen; Tests können einzelne
/// Await-/I/O-Punkte ersetzen, ohne Mikrofon, Server oder Dateisystem zu starten.
@MainActor
protocol DictationRecorder: AnyObject {
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    var onFailure: (@Sendable (Error) -> Void)? { get set }
    func start() throws
    func stop()
}

protocol DictationSegmenter: AnyObject, Sendable {
    var onSegment: ((VadSegmenter.Segment) -> Void)? { get set }
    var onAutoStop: (() -> Void)? { get set }
    var currentLevelDb: Double { get }
    var fallbackReason: String? { get }
    var onFallback: ((String) -> Void)? { get set }
    func process(_ samples: [Float])
    func flush()
}

extension DictationSegmenter {
    var fallbackReason: String? { nil }
    var onFallback: ((String) -> Void)? { get { nil } set {} }
}

protocol DictationTranscriber: AnyObject, Sendable {
    func transcribe(samples: [Float]) async throws -> String
    func transcribe(wavFile: URL) async throws -> String
    func isReachable() async -> Bool
    func health() async -> WhisperClient.Health
}

extension DictationTranscriber {
    func health() async -> WhisperClient.Health { await isReachable() ? .ready : .unavailable }
}

protocol DictationServer: AnyObject, Sendable {
    func ensureRunning(reachability: any DictationTranscriber) async throws
    func stop()
}

protocol DictationCleanup: AnyObject, Sendable {
    var onFallbackEndpoint: (@Sendable (String) -> Void)? { get set }
    var onPrimaryRetry: (@Sendable () -> Void)? { get set }
    func clean(_ rawText: String) async -> CleanupService.Result
    func warmUp()
    func warmUp(pinnedOnly: Bool)
}

extension DictationCleanup {
    func warmUp(pinnedOnly: Bool) {
        if !pinnedOnly { warmUp() }
    }
}

protocol DictationWavWriter: AnyObject, Sendable {
    var url: URL { get }
    func append(_ samples: [Float]) throws
    func finish() throws
}

extension AudioRecorder: DictationRecorder {}
extension VadSegmenter: DictationSegmenter {}
extension WhisperClient: DictationTranscriber {}
extension CleanupService: DictationCleanup {}
extension WavFileWriter: DictationWavWriter {}

struct DictationDependencies {
    let transcriber: any DictationTranscriber
    let server: any DictationServer
    let cleanup: any DictationCleanup
    let makeRecorder: @MainActor (Config.Audio) -> any DictationRecorder
    let makeSegmenter: @Sendable (Config.Vad) async -> any DictationSegmenter
    let makeWavWriter: @Sendable (URL) throws -> any DictationWavWriter
    var makeTranscriber: (@Sendable (Config.Whisper) -> any DictationTranscriber)? = nil
    var monotonicTime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var beforeFileDecodeChunk: (@Sendable (Int) async -> Void)? = nil
    var requestMicrophoneAccess: @Sendable () async -> Bool = { await AudioRecorder.requestMicrophoneAccess() }

    static func live(config: Config) -> Self {
        Self(
            transcriber: WhisperClient(config: config.whisper),
            server: WhisperServerManager(config: config.whisper),
            cleanup: CleanupService(config: config.cleanup),
            makeRecorder: { AudioRecorder(config: $0) },
            makeSegmenter: { await VadSegmenter.prepared(config: $0) },
            makeWavWriter: { try WavFileWriter(url: $0) }
        )
    }
}
