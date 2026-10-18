import Foundation
import StillePostCore

// Isolierte Geräteprüfung gegen die echte Brücke. Token nur aus privater Datei;
// bestehende App-Konfiguration, Schlüsselbund und Listener bleiben unberührt.
@main struct IOSBridgeFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 4, let port = Int(CommandLine.arguments[1]) else {
            throw FixtureError.arguments
        }
        let tokenFile = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw FixtureError.arguments }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let metrics = Metrics(url: output.appendingPathComponent("metrics.json"))
        var config = Config()
        config.whisper.language = "de"; config.whisper.autostart = false
        config.cleanup.localOnly = true; config.cleanup.fallbacks = []
        config.bridge.enabled = true; config.bridge.port = port
        let live = BridgeHandlers.live(config: config, version: "ios-development-test")
        let handlers = BridgeHandlers(transcribe: { data in
            metrics.audio(data.count)
            return try await live.transcribe(data)
        }, cleanup: { text in
            metrics.cleanup()
            let result = await live.cleanup(text)
            metrics.result(result.text)
            return result
        }, cleanupEnabled: true, version: "ios-development-test")
        let router = BridgeRouter(handlers: handlers, maxBodyBytes: 5_000_000, tokenProvider: { token })
        let server = BridgeServer(config: config.bridge, router: router, tokenStatus: { .token(token) })
        try server.start()
        metrics.ready()
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
    enum FixtureError: Error { case arguments }
}

private final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var value: [String: Any] = ["ready": false, "transcriptions": 0, "cleanups": 0]
    init(url: URL) { self.url = url }
    func ready() { update { $0["ready"] = true } }
    func audio(_ bytes: Int) {
        update { $0["transcriptions"] = ($0["transcriptions"] as? Int ?? 0) + 1; $0["lastAudioBytes"] = bytes }
    }
    func cleanup() { update { $0["cleanups"] = ($0["cleanups"] as? Int ?? 0) + 1 } }
    func result(_ text: String) {
        update {
            $0["resultCharacters"] = text.count
            $0["hasNegation"] = text.lowercased().contains("keine")
            $0["hasTwelve"] = text.contains("12") || text.lowercased().contains("zwölf")
        }
    }
    private func update(_ change: (inout [String: Any]) -> Void) {
        lock.lock(); defer { lock.unlock() }; change(&value)
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
