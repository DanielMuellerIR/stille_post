import Foundation

/// Die Arbeitsschritte, die die Brücke ausführt. Als einspeisbare Funktionen,
/// damit Tests die ganze Route ohne whisper-server und ohne Ollama prüfen können.
public struct BridgeHandlers: Sendable {
    /// Audio-Bytes (WAV, AAC, …) -> Rohtext.
    public var transcribe: @Sendable (Data) async throws -> String
    /// Rohtext -> bereinigter Text.
    public var cleanup: @Sendable (String) async -> CleanupService.Result
    /// Ist die Bereinigung überhaupt eingeschaltet?
    public var cleanupEnabled: Bool
    /// Produktversion für `/v1/health`.
    public var version: String

    public init(transcribe: @escaping @Sendable (Data) async throws -> String,
                cleanup: @escaping @Sendable (String) async -> CleanupService.Result,
                cleanupEnabled: Bool,
                version: String) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.cleanupEnabled = cleanupEnabled
        self.version = version
    }
}

/// Beantwortet Brücken-Anfragen.
///
/// Serielle Abarbeitung ist hier Pflicht: Zwei gleichzeitige Diktate würden sich
/// um denselben whisper-server und dasselbe Bereinigungsmodell streiten — auf
/// einem Mac mit knappem Speicher heißt das im schlimmsten Fall, dass beide
/// scheitern. Der `actor` allein garantiert das NICHT: Jedes `await` auf die
/// Handler gibt seine Isolation frei, und eine zweite Anfrage könnte einfach
/// hineinlaufen. Deshalb hängen sich die schweren Routen zusätzlich über
/// `serialized` in eine echte Warteschlange (siehe `pipelineTail`).
public actor BridgeRouter {

    private let tokenProvider: @Sendable () -> String?
    private let handlers: BridgeHandlers
    /// Zweite Schutzschicht neben `BridgeHTTP.parse`: Auch direkt erzeugte
    /// `BridgeRequest`-Werte (andere Aufrufer als der Server, Tests) unterliegen
    /// damit der Größengrenze.
    private let maxBodyBytes: Int
    /// Ende der Warteschlange der schweren Routen: Jede neue Anfrage wartet auf
    /// die Task hier hinten, bevor sie selbst startet.
    private var pipelineTail: Task<BridgeResponse, Never>?

    public init(handlers: BridgeHandlers, maxBodyBytes: Int,
                tokenProvider: @escaping @Sendable () -> String? = { BridgeToken.load() }) {
        self.handlers = handlers
        self.maxBodyBytes = maxBodyBytes
        self.tokenProvider = tokenProvider
    }

    public func respond(to request: BridgeRequest) async -> BridgeResponse {
        guard isAuthorized(bearerToken: request.bearerToken) else {
            // Bewusst dieselbe knappe Antwort für „kein Token geschickt“, „falsches
            // Token“ und „auf dem Mac ist noch keins angelegt“: Die Gegenseite soll
            // aus der Antwort nichts über den Zustand lernen. Der Grund steht im
            // lokalen Protokoll auf stderr.
            return .error(status: 401, message: L10n.text("core.bridge.unauthorized"))
        }
        guard request.body.count <= maxBodyBytes else {
            return .error(status: 413, message: L10n.format(
                "core.bridge.too_large", ByteSize.megabytes(Int64(maxBodyBytes))
            ))
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            // Bewusst NICHT in der Warteschlange: Health soll auch während eines
            // laufenden Diktats sofort antworten.
            return .json(status: 200, object: [
                "ok": true,
                "version": handlers.version,
                "cleanup": handlers.cleanupEnabled,
            ])

        case ("POST", "/v1/dictate"):
            return await serialized { await self.dictate(request) }

        case ("POST", "/v1/cleanup"):
            return await serialized { await self.cleanupOnly(request) }

        case (_, "/v1/health"), (_, "/v1/dictate"), (_, "/v1/cleanup"):
            return .error(status: 405, message: L10n.text("core.bridge.method_not_allowed"))

        default:
            return .error(status: 404, message: L10n.text("core.bridge.unknown_route"))
        }
    }

    /// Reiht eine schwere Anfrage ans Ende der Warteschlange ein: Sie startet
    /// erst, wenn alle zuvor angenommenen fertig sind — Transkription und
    /// Bereinigung überlappen so nie, egal wie viele Verbindungen gleichzeitig
    /// offen sind.
    private func serialized(
        _ work: @escaping @Sendable () async -> BridgeResponse
    ) async -> BridgeResponse {
        let previous = pipelineTail
        let task = Task { () -> BridgeResponse in
            _ = await previous?.value  // Ergebnis egal — nur die Reihenfolge zählt
            return await work()
        }
        pipelineTail = task
        return await task.value
    }

    // MARK: - Routen

    /// Audio rein, fertiger Text raus. `?raw=1` überspringt die Bereinigung —
    /// gedacht für Diagnose und für den Fall, dass nur die Spracherkennung zählt.
    private func dictate(_ request: BridgeRequest) async -> BridgeResponse {
        guard !request.body.isEmpty else {
            return .error(status: 400, message: L10n.text("core.bridge.audio_empty"))
        }
        let sttStarted = Date()
        let raw: String
        do {
            raw = TranscriptPolish.flattenLineBreaks(try await handlers.transcribe(request.body))
        } catch {
            return .error(status: 500, message: error.localizedDescription)
        }
        let sttSeconds = Date().timeIntervalSince(sttStarted)

        // Leeres Ergebnis ist kein Fehler: Whisper hat nur Stille gehört.
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(status: 200, object: [
                "text": "", "raw": "", "sttSec": rounded(sttSeconds),
            ])
        }

        let wantsRaw = request.query["raw"] == "1"
        guard !wantsRaw, handlers.cleanupEnabled else {
            return .json(status: 200, object: [
                "text": raw, "raw": raw, "sttSec": rounded(sttSeconds),
            ])
        }
        let cleanupStarted = Date()
        let result = await handlers.cleanup(raw)
        var object = payload(raw: raw, result: result,
                             cleanupSeconds: Date().timeIntervalSince(cleanupStarted))
        object["sttSec"] = rounded(sttSeconds)
        return .json(status: 200, object: object)
    }

    /// Nur die Bereinigung. Damit kann ein Gerät, das selbst transkribiert
    /// (Apple-Diktat oder später Whisper auf dem iPhone), die Textqualität von
    /// Stille Post nutzen, ohne Audio zu übertragen.
    private func cleanupOnly(_ request: BridgeRequest) async -> BridgeResponse {
        guard let text = String(data: request.body, encoding: .utf8) else {
            return .error(status: 415, message: L10n.text("core.bridge.text_not_utf8"))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(status: 400, message: L10n.text("core.bridge.text_empty"))
        }
        guard handlers.cleanupEnabled else {
            return .error(status: 503, message: L10n.text("core.bridge.cleanup_off"))
        }
        let started = Date()
        let result = await handlers.cleanup(text)
        return .json(status: 200, object: payload(
            raw: text, result: result, cleanupSeconds: Date().timeIntervalSince(started)
        ))
    }

    // MARK: - Hilfsfunktionen

    /// Ist überhaupt ein Token eingerichtet? `nonisolated`, weil nur die
    /// unveränderliche `tokenProvider`-Konfiguration gelesen wird — der Server
    /// prüft das vor dem Öffnen des Ports.
    public nonisolated var hasToken: Bool {
        guard let token = tokenProvider() else { return false }
        return !token.isEmpty
    }

    /// Stimmt das Token? Ebenfalls `nonisolated`, damit die Verbindungsschicht
    /// schon nach dem vollständigen Kopf prüfen kann — BEVOR sie den
    /// (möglicherweise großen) Body puffert.
    public nonisolated func isAuthorized(bearerToken: String?) -> Bool {
        guard let expected = tokenProvider(), !expected.isEmpty,
              let presented = bearerToken else { return false }
        return BridgeToken.matches(presented, expected: expected)
    }

    /// Gemeinsame Antwortform für beide Text-Routen. `text` ist das Ergebnis,
    /// alles andere Diagnose — die Gegenseite darf sie ignorieren.
    private func payload(raw: String, result: CleanupService.Result,
                         cleanupSeconds: TimeInterval) -> [String: Any] {
        var object: [String: Any] = [
            "text": result.text,
            "raw": raw,
            "cleanupSec": rounded(cleanupSeconds),
            "usedFallback": result.usedFallback,
        ]
        if let endpoint = result.endpoint { object["endpoint"] = endpoint }
        if let reason = result.fallbackReason { object["fallbackReason"] = reason }
        return object
    }

    private func rounded(_ seconds: TimeInterval) -> Double {
        (seconds * 100).rounded() / 100
    }
}

public extension BridgeHandlers {
    /// Verdrahtet die echten Bausteine: Audio -> whisper-server (immer lokal!) ->
    /// genau ein Bereinigungsaufruf über den vollständigen Text.
    ///
    /// Der whisper-server wird bei Bedarf gestartet, genau wie beim Diktat am Mac.
    static func live(config: Config, version: String) -> BridgeHandlers {
        let whisper = WhisperClient(config: config.whisper)
        let serverManager = WhisperServerManager(config: config.whisper)
        let cleanup = CleanupService(config: config.cleanup)
        return BridgeHandlers(
            transcribe: { data in
                let samples = try AudioDecoder.samples16kMono(from: data)
                try await serverManager.ensureRunning(client: whisper)
                return try await whisper.transcribe(samples: samples)
            },
            cleanup: { text in await cleanup.clean(text) },
            cleanupEnabled: config.cleanup.enabled,
            version: version
        )
    }
}
