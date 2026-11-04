#if os(Linux)
import Foundation
import Glibc

/// Privates, begrenztes JSONL-Protokoll zwischen GUI und unverändertem Diktierkern.
/// Audio wird in kleinen Float32-Blöcken über dieselbe vererbte Pipe übertragen.
public final class LinuxWorker {
    private var config: Config
    private var engine: DictationEngine
    private let lock = NSLock()
    private let ollama = LinuxOllamaService()
    private var pendingMessages = 0
    private let flow = NSCondition()

    public init() throws {
        LinuxNetworkBootstrap.prepare()
        umask(0o077)
        config = try ConfigFile().loadSnapshot()
        engine = DictationEngine(config: config)
        AudioRecorder.capture = { [weak self] active, device in self?.send(["event":"capture", "active":active, "device":device]) }
        engine.onStateChange = { [weak self] state in
            let value: String
            switch state {
            case .idle: value = "idle"
            case .starting: value = "starting"
            case .recording: value = "recording"
            case .paused: value = "paused"
            case .resuming: value = "starting"
            case .processing: value = "processing"
            case .error: value = "error"
            }
            self?.send(["event":"state", "state":value])
            if case .error = state { self?.send(["event":"error", "message":"Verarbeitung fehlgeschlagen. Aufnahme bleibt im Verlauf zur Diagnose erhalten."]) }
        }
        engine.onResult = { [weak self] result in
            self?.send(["event":"result", "text":result.text, "rawFallback":result.entry?.cleanupFellBack ?? false,
                        "localFallback":result.entry?.cleanupEndpoint?.contains("127.0.0.1") ?? false])
        }
        engine.onCleanupFallback = { [weak self] _ in self?.send(["event":"notice", "message":"Primärdienst nicht verfügbar – lokales Modell wird verwendet."]) }
        engine.onCleanupPrimaryRetry = { [weak self] in self?.send(["event":"notice", "message":"Primärdienst wird erneut versucht."]) }
        engine.onVadFallback = { [weak self] _ in self?.send(["event":"notice", "message":"RMS-Stilleerkennung aktiv."]) }
    }

    public func run() {
        send(["event":"ready", "protocol":1])
        Task { await ollama.startIfNeeded() }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 32768)
                while true {
                    let count = Glibc.read(STDIN_FILENO, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; throw LinuxFailure.protocolFailure }
                    pending.append(contentsOf: buffer.prefix(count))
                    guard pending.count <= 262144 else { throw LinuxFailure.protocolFailure }
                    while let index = pending.firstIndex(of: 10) {
                        let line = Data(pending.prefix(upTo: index)); pending.removeSubrange(...index)
                        guard line.count <= 131072,
                              let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw LinuxFailure.protocolFailure }
                        flow.lock()
                        while pendingMessages >= 8 { flow.wait() }
                        pendingMessages += 1; flow.unlock()
                        DispatchQueue.main.async { [self] in
                            handle(message)
                            flow.lock(); pendingMessages -= 1; flow.signal(); flow.unlock()
                        }
                    }
                }
            } catch { send(["event":"error", "message":"Die Verbindung zur Oberfläche wurde unterbrochen."]) }
            DispatchQueue.main.async { [self] in Task { await engine.shutdown().value; ollama.stop(); exit(0) } }
        }
        dispatchMain()
    }
    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), data.count < 4 * 1024 * 1024 else { return }
        lock.lock(); defer { lock.unlock() }
        do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
        catch { exit(1) }
    }
    private func handle(_ message: [String: Any]) {
        guard let command = message["command"] as? String else { return }
        switch command {
        case "start": engine.start()
        case "stop": engine.stop()
        case "toggle": engine.toggle()
        case "pause": engine.pause()
        case "resume": engine.resume()
        case "cancel": engine.cancel()
        case "captureError": AudioRecorder.active?.onFailure?(LinuxFailure.capture)
        case "samples":
            guard let encoded = message["data"] as? String, let data = Data(base64Encoded: encoded),
                  data.count <= 65536, data.count % 4 == 0 else { AudioRecorder.active?.onFailure?(LinuxFailure.protocolFailure); return }
            let values: [Float] = data.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
            }
            guard values.allSatisfy({ $0.isFinite }) else { AudioRecorder.active?.onFailure?(LinuxFailure.capture); return }
            AudioRecorder.active?.onSamples?(values)
        case "import":
            guard let path = message["path"] as? String, path.hasPrefix("/"), !engine.hasInFlightRequests else { return }
            engine.importAudioFile(URL(fileURLWithPath: path))
        case "history":
            Task { [self] in
                do {
                    let entries = try await engine.history.listAsync()
                    let data = try JSONEncoder().encode(Array(entries.prefix(100)))
                    send(["event":"history", "entries":try JSONSerialization.jsonObject(with: data)])
                } catch { send(["event":"error", "message":"Verlauf konnte nicht gelesen werden."]) }
            }
        case "deleteHistory":
            guard let value = message["id"] as? String, let id = UUID(uuidString: value) else { return }
            Task { [self] in
                do { try await engine.history.deleteAsync(id: id); handle(["command":"history"]) }
                catch { send(["event":"error", "message":"Eintrag konnte nicht gelöscht werden."]) }
            }
        case "config":
            if let data = try? JSONEncoder().encode(config), let object = try? JSONSerialization.jsonObject(with: data) {
                send(["event":"config", "config":object])
            }
        case "saveConfig":
            guard !engine.hasInFlightRequests, let object = message["config"],
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            do {
                let replacement = try JSONDecoder().decode(Config.self, from: data)
                _ = try WhisperEndpoint(serverURL: replacement.whisper.serverURL)
                try replacement.save(expected: config)
                config = replacement; engine.configure(config)
                send(["event":"notice", "message":"Einstellungen gespeichert."])
            } catch { send(["event":"error", "message":"Einstellungen ungültig oder inzwischen geändert."]) }
        case "quit": Task { [self] in await engine.shutdown().value; ollama.stop(); exit(0) }
        default: break
        }
    }
    public static func cleanStandardInput() async throws {
        let input = try FileHandle.standardInput.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard input.count <= 1024 * 1024, let raw = String(data: input, encoding: .utf8) else { throw LinuxFailure.protocolFailure }
        let config = try ConfigFile().loadSnapshot()
        let result = await CleanupService(config: config.cleanup).clean(raw)
        let output: [String: Any] = ["text":result.text, "rawFallback":result.usedFallback, "endpoint":result.endpoint ?? ""]
        try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: output))
    }
}
#endif
