#if os(Linux)
import Foundation
import FoundationNetworking
import Glibc

/// Die Linux-App spricht Dienste immer direkt an. libcurl darf geerbte
/// Proxyvariablen insbesondere beim Audiotransport nicht berücksichtigen.
enum LinuxNetworkBootstrap {
    static let initialized: Void = {
        for key in [
            "http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        ] {
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
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
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

enum LinuxFailure: Error, LocalizedError {
    case capture, decode, secret, protocolFailure, environmentToken
    var errorDescription: String? {
        switch self {
        case .capture: return L10n.text("linux.error.capture")
        case .decode: return L10n.text("linux.error.decode")
        case .secret: return L10n.text("linux.error.secret")
        case .protocolFailure: return L10n.text("linux.error.protocol")
        case .environmentToken: return L10n.text("linux.bridge.environment_token")
        }
    }
}

public enum AudioDecoder {
    public static func samples16kMono(from data: Data) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "stillepost-received-\(UUID().uuidString).audio")
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FileReader(url: url, maxSampleCount: maxSampleCount)
        var samples: [Float] = []
        while let block = try reader.read() { samples.append(contentsOf: block) }
        return samples
    }
    public static let maxSampleCount = 16000 * 3600
    public enum DecodeError: Error, LocalizedError {
        case empty, unsupported(String), tooLong(seconds: Int)
        public var errorDescription: String? {
            switch self {
            case .empty: return L10n.text("linux.audio.empty")
            case .unsupported: return L10n.text("linux.audio.unsupported")
            case .tooLong: return L10n.text("linux.audio.too_long")
            }
        }
    }
    /// FFmpeg läuft lokal, ohne Netzwerkprotokolle, mit begrenzter Ausgabe.
    final class FileReader {
        private let process = Process()
        private let output = Pipe()
        private let maximum: Int
        private(set) var sampleCount = 0
        let estimatedDuration: TimeInterval? = nil
        init(url: URL, maxSampleCount: Int) throws {
            maximum = maxSampleCount
            let bundled = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                .deletingLastPathComponent().appendingPathComponent("ffmpeg").path
            process.executableURL = URL(
                fileURLWithPath: FileManager.default.isExecutableFile(atPath: bundled)
                    ? bundled : "/usr/bin/ffmpeg")
            process.arguments = [
                "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe", "-i", url.path,
                "-vn", "-t", String(maxSampleCount / 16000 + 1), "-f", "f32le", "-ar", "16000",
                "-ac",
                "1", "pipe:1",
            ]
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
            guard let bytes = try output.fileHandleForReading.read(upToCount: 65536), !bytes.isEmpty
            else {
                process.waitUntilExit()
                guard process.terminationStatus == 0, sampleCount > 0 else {
                    throw LinuxFailure.decode
                }
                return nil
            }
            // codereview-ok: Foundation füllt bis zur angefragten Länge oder EOF; nur ein unvollständiges Sample am EOF verletzt die 4-Byte-Grenze (Swift 6.2.1 geprüft, 2026-11-07).
            guard bytes.count % 4 == 0 else { throw LinuxFailure.decode }
            let values: [Float] = bytes.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map {
                    Float(
                        bitPattern: UInt32(
                            littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
                }
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
    static func load(service: String = CleanupService.keychainService) -> String? {
        try? loadChecked(service: service)
    }
    static func loadChecked(service: String) throws -> String? {
        let data = try execute(["lookup", "service", service], input: nil, allowMissing: true)
        if data.isEmpty { return nil }
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
            !value.isEmpty
        else { throw LinuxFailure.secret }
        return value
    }
    static func store(_ key: String, service: String = CleanupService.keychainService) throws {
        _ = try execute(
            ["store", "--label=Stille Post", "service", service], input: Data((key + "\n").utf8))
    }
    private static func execute(_ args: [String], input: Data?, allowMissing: Bool = false) throws
        -> Data
    {
        let process = Process()
        let out = Pipe()
        let pipe = Pipe()
        let errors = Pipe()
        let bundled = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("secret-tool").path
        process.executableURL = URL(
            fileURLWithPath: FileManager.default.isExecutableFile(atPath: bundled)
                ? bundled : "/usr/bin/secret-tool")
        process.arguments = args
        process.standardOutput = out
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : pipe
        try process.run()
        if let input {
            try pipe.fileHandleForWriting.write(contentsOf: input)
            try pipe.fileHandleForWriting.close()
        }
        let timeout = DispatchWorkItem { LinuxChildProcess.stop(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let result = out.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        if allowMissing && process.terminationReason == .exit && process.terminationStatus == 1
            && diagnostic.isEmpty && result.isEmpty
        {
            return Data()
        }
        guard process.terminationStatus == 0, result.count < 65536 else {
            throw LinuxFailure.secret
        }
        return result
    }
}
/// Nur den eigenen, leeren Loopback-Dienst starten; vorhandene Dienste bleiben
/// unangetastet. Modelle lädt erst die bestehende Cleanup-Kette bei Bedarf.
final class LinuxOllamaService {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    func startIfNeeded(configuration: Config) async {
        let endpoints =
            configuration.cleanup.chain
            + configuration.profiles.flatMap {
                $0.cleanup.map { [$0.primary] + $0.fallbacks } ?? []
            }
        guard lock.withLock({ !stopped && process?.isRunning != true }),
            endpoints.contains(where: {
                guard $0.provider == "ollama", let url = URL(string: $0.ollamaURL) else {
                    return false
                }
                return url.host == "127.0.0.1" && (url.port ?? 80) == 11434
            })
        else { return }
        let url = URL(string: "http://127.0.0.1:11434/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        if let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        {
            return
        }
        launch()
    }
    private func launch() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, process?.isRunning != true else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent()
        let binary = directory.appendingPathComponent("ollama")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11434"
        environment["OLLAMA_MODELS"] =
            Config.appSupportDir.appendingPathComponent("ollama-models").path
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            self.process = process
        } catch { return }
    }
    func stop() {
        let child = lock.withLock { () -> Process? in
            stopped = true
            let child = process
            process = nil
            return child
        }
        LinuxChildProcess.stop(child)
    }
    deinit { LinuxChildProcess.stop(process) }
}

public enum BridgeToken {
    public enum Outcome { case token(String), missing, failed(Int32) }
    public static let keychainService = "StillePost Bridge Token"
    public static func loadOutcome() -> Outcome {
        if let value = ProcessInfo.processInfo.environment["STILLEPOST_BRIDGE_TOKEN"],
            !value.isEmpty
        {
            return .token(value)
        }
        do {
            return try LinuxSecretStore.loadChecked(service: keychainService).map { .token($0) }
                ?? .missing
        } catch { return .failed(-1) }
    }
    public static func load() -> String? {
        if let value = ProcessInfo.processInfo.environment["STILLEPOST_BRIDGE_TOKEN"],
            !value.isEmpty
        {
            return value
        }
        if case .token(let value) = loadOutcome() { return value }
        return nil
    }
    public static func matches(_ candidate: String, expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        guard !b.isEmpty else { return false }
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            difference |=
                (index < a.count ? Int(a[index]) : 0) ^ (index < b.count ? Int(b[index]) : 0)
        }
        return difference == 0
    }
}
#endif
