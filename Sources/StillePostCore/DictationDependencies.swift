import Foundation

/// Kleine interne Grenzen für den zustandsreichen Diktat-Lifecycle. Produktiv
/// stehen dahinter unverändert die bestehenden Klassen; Tests können einzelne
/// Await-/I/O-Punkte ersetzen, ohne Mikrofon, Server oder Dateisystem zu starten.
protocol DictationRecorder: AnyObject {
    var onSamples: (([Float]) -> Void)? { get set }
    func start() throws
    func stop()
}

protocol DictationSegmenter: AnyObject {
    var onSegment: ((VadSegmenter.Segment) -> Void)? { get set }
    var onAutoStop: (() -> Void)? { get set }
    var currentLevelDb: Double { get }
    func process(_ samples: [Float])
    func flush()
}

protocol DictationTranscriber: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
    func transcribe(wavFile: URL) async throws -> String
    func isReachable() async -> Bool
}

protocol DictationServer: AnyObject {
    func ensureRunning(reachability: any DictationTranscriber) async throws
    func stop()
}

protocol DictationCleanup: AnyObject {
    var onFallbackEndpoint: ((String) -> Void)? { get set }
    var onPrimaryRetry: (() -> Void)? { get set }
    func clean(_ rawText: String) async -> CleanupService.Result
    func warmUp()
}

protocol DictationWavWriter: AnyObject {
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
    let makeRecorder: (Config.Audio) -> any DictationRecorder
    let makeSegmenter: (Config.Vad) -> any DictationSegmenter
    let makeWavWriter: (URL) throws -> any DictationWavWriter

    static func live(config: Config) -> Self {
        Self(
            transcriber: WhisperClient(config: config.whisper),
            server: WhisperServerManager(config: config.whisper),
            cleanup: CleanupService(config: config.cleanup),
            makeRecorder: { AudioRecorder(config: $0) },
            makeSegmenter: { VadSegmenter(config: $0) },
            makeWavWriter: { try WavFileWriter(url: $0) }
        )
    }
}
