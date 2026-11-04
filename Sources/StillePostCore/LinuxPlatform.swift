#if os(Linux)
import Foundation
import FoundationNetworking
import Glibc

/// Die Linux-App spricht Dienste immer direkt an. libcurl darf geerbte
/// Proxyvariablen insbesondere beim Audiotransport nicht berücksichtigen.
enum LinuxNetworkBootstrap {
    static let initialized: Void = {
        for key in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"] {
            unsetenv(key)
        }
        setenv("NO_PROXY", "*", 1)
        setenv("no_proxy", "*", 1)
    }()
    static func prepare() { _ = initialized }
}

/// Foundation-Kindprozesse können unter Linux eine blockierte Signalmaske
/// erben. Nur eigene Prozesse nach kurzer TERM-Frist nötigenfalls hart beenden.
enum LinuxChildProcess {
    static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

/// PCM kommt ausschließlich über die private Elternprozess-Pipe vom Qt-Adapter.
public final class AudioRecorder {
    public enum RecorderError: Error { case recordingInterrupted }
    public static var capture: ((Bool, String) -> Void)?
    public static weak var active: AudioRecorder?
    public var onSamples: (([Float]) -> Void)?
    public var onFailure: ((Error) -> Void)?
    private let config: Config.Audio
    public init(config: Config.Audio = Config.Audio()) { self.config = config }
    public static func requestMicrophoneAccess() async -> Bool { true }
    public func start() throws {
        guard Self.active == nil, Self.capture != nil else { throw LinuxFailure.capture }
        Self.active = self
        Self.capture?(true, config.inputDeviceUID)
    }
    public func stop() {
        guard Self.active === self else { return }
        Self.active = nil
        Self.capture?(false, "")
    }
}

protocol SpeechActivityDetector: AnyObject {
    var frameSize: Int { get }
    func isSpeech(_ samples: [Float]) throws -> Bool
}
extension VadSegmenter {
    public static func prepared(config: Config.Vad) async -> VadSegmenter {
        VadSegmenter(config: config, detector: nil,
                     fallbackReason: config.detector == .silero ? "Silero/CoreML ist unter Linux nicht verfügbar; RMS aktiv." : nil)
    }
}

enum LinuxFailure: Error, LocalizedError {
    case capture, decode, secret, protocolFailure
    var errorDescription: String? {
        switch self {
        case .capture: return "Audioeingang nicht verfügbar."
        case .decode: return "Audio konnte nicht vollständig dekodiert werden."
        case .secret: return "Secret Service ist nicht verfügbar oder gesperrt."
        case .protocolFailure: return "Ungültige oder übergroße Worker-Nachricht."
        }
    }
}

public enum AudioDecoder {
    public static let maxSampleCount = 16000 * 3600
    public enum DecodeError: Error, LocalizedError {
        case empty, unsupported(String), tooLong(seconds: Int)
        public var errorDescription: String? {
            switch self {
            case .empty: return "Audio ist leer."
            case .unsupported: return "Audioformat nicht unterstützt."
            case .tooLong: return "Audio überschreitet die Längengrenze."
            }
        }
    }
    /// FFmpeg läuft lokal, ohne Netzwerkprotokolle, mit begrenzter Ausgabe.
    final class FileReader {
        private let process = Process()
        private let output = Pipe()
        private let maximum: Int
        private(set) var sampleCount = 0
        let estimatedSampleCount = 0
        let estimatedDuration: TimeInterval? = nil
        init(url: URL, maxSampleCount: Int) throws {
            maximum = maxSampleCount
            let bundled = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("ffmpeg").path
            process.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/ffmpeg")
            process.arguments = ["-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", url.path,
                                 "-vn", "-t", String(maxSampleCount / 16000 + 1), "-f", "f32le", "-ar", "16000", "-ac", "1", "pipe:1"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        deinit {
            LinuxChildProcess.stop(process)
            try? output.fileHandleForReading.close()
        }
        func read() throws -> [Float]? {
            try Task.checkCancellation()
            guard let bytes = try output.fileHandleForReading.read(upToCount: 65536), !bytes.isEmpty else {
                process.waitUntilExit()
                guard process.terminationStatus == 0, sampleCount > 0 else { throw LinuxFailure.decode }
                return nil
            }
            guard bytes.count % 4 == 0 else { throw LinuxFailure.decode }
            let values: [Float] = bytes.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
            }
            sampleCount += values.count
            guard sampleCount <= maximum, values.allSatisfy({ $0.isFinite }) else {
                throw DecodeError.tooLong(seconds: maximum / 16000)
            }
            return values
        }
    }
}

enum LinuxSecretStore {
    static func load() -> String? {
        guard let data = try? execute(["lookup", "service", CleanupService.keychainService], input: nil),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines), !value.isEmpty else { return nil }
        return value
    }
    static func store(_ key: String) throws {
        _ = try execute(["store", "--label=Stille Post", "service", CleanupService.keychainService], input: Data((key + "\n").utf8))
    }
    private static func execute(_ args: [String], input: Data?) throws -> Data {
        let process = Process(), out = Pipe(), pipe = Pipe()
        let bundled = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("secret-tool").path
        process.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/secret-tool")
        process.arguments = args
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe
        try process.run()
        if let input { try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close() }
        let timeout = DispatchWorkItem { LinuxChildProcess.stop(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let result = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0, result.count < 65536 else { throw LinuxFailure.secret }
        return result
    }
}
/// Nur den eigenen, leeren Loopback-Dienst starten; vorhandene Dienste bleiben
/// unangetastet. Modelle lädt erst die bestehende Cleanup-Kette bei Bedarf.
final class LinuxOllamaService {
    private var process: Process?
    func startIfNeeded() async {
        let url = URL(string: "http://127.0.0.1:11434/api/tags")!
        var request = URLRequest(url: url); request.timeoutInterval = 1
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200 { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let binary = directory.appendingPathComponent("ollama")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11434"
        environment["OLLAMA_MODELS"] = Config.appSupportDir.appendingPathComponent("ollama-models").path
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); self.process = process } catch { return }
    }
    func stop() { LinuxChildProcess.stop(process); process = nil }
    deinit { stop() }
}

#endif
