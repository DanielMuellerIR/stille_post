import Foundation

/// Startet und überwacht den lokalen whisper-server (whisper.cpp) als Kindprozess.
///
/// Die App ist damit selbstversorgend: Läuft auf dem konfigurierten Port schon ein
/// Server (z. B. von Hand oder per launchd gestartet), wird der benutzt. Sonst
/// startet die App den Server selbst und beendet ihn beim eigenen Ende wieder.
public final class WhisperServerManager: DictationServer {

    private let config: Config.Whisper
    private var process: Process?

    public convenience init(config: Config.Whisper) {
        self.init(config: config, ownedProcess: nil)
    }

    /// `ownedProcess` ist eine enge Testgrenze für den Besitzvertrag: Nur der hier
    /// gespeicherte Kindprozess darf beim Scope-Ende beendet werden.
    init(config: Config.Whisper, ownedProcess: Process?) {
        self.config = config
        self.process = ownedProcess
    }

    deinit {
        stop()
    }

    /// Stellt sicher, dass ein whisper-server erreichbar ist.
    /// Wirft mit verständlicher Meldung, wenn Binary/Modell fehlen oder der Start scheitert.
    public func ensureRunning(client: WhisperClient) async throws {
        try await ensureRunning(reachability: client)
    }

    func ensureRunning(reachability client: any DictationTranscriber) async throws {
        let endpoint: WhisperEndpoint
        do {
            endpoint = try WhisperEndpoint(serverURL: config.serverURL)
        } catch {
            throw ServerError.notReachable(error.localizedDescription)
        }
        if await client.isReachable() { return }
        guard config.autostart else {
            throw ServerError.notReachable(config.serverURL)
        }

        let binary = Config.expandPath(config.binaryPath)
        let model = Config.expandPath(config.modelPath)
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw ServerError.binaryMissing(binary)
        }
        guard FileManager.default.fileExists(atPath: model) else {
            throw ServerError.modelMissing(model)
        }
        // Server als Kindprozess starten. Er lauscht nur auf localhost —
        // nichts ist von außen erreichbar.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "-m", model,
            "--host", "127.0.0.1",
            "--port", String(endpoint.port),
            "-t", String(config.threads),
        ]
        // Server-Logs nicht in unser Terminal mischen.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        // Warten, bis der Server das Modell geladen hat und antwortet (max. ~30 s —
        // das Modell ist ~1,6 GB groß, das Laden dauert beim ersten Mal ein paar Sekunden).
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if await client.isReachable() { return }
            if !process.isRunning {
                throw ServerError.startFailed(binary)
            }
        }
        throw ServerError.startTimeout
    }

    /// Beendet den selbst gestarteten Server (fremde Server bleiben unangetastet).
    public func stop() {
        let ownedProcess = process
        process = nil
        if ownedProcess?.isRunning == true { ownedProcess?.terminate() }
    }

    public enum ServerError: Error, LocalizedError {
        case notReachable(String)
        case binaryMissing(String)
        case modelMissing(String)
        case startFailed(String)
        case startTimeout

        public var errorDescription: String? {
            switch self {
            case .notReachable(let url):
                return L10n.format("core.server.not_reachable", url)
            case .binaryMissing(let path):
                return L10n.format("core.server.binary_missing", path)
            case .modelMissing(let path):
                return L10n.format("core.server.model_missing", path)
            case .startFailed(let path):
                return L10n.format("core.server.start_failed", path)
            case .startTimeout:
                return L10n.text("core.server.start_timeout")
            }
        }
    }
}
