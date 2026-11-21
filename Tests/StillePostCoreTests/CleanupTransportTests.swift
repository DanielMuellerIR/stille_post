import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StillePostCore

final class CleanupTransportTests: XCTestCase {
    // MARK: keep_alive (wie lange das Modell geladen bleibt)

    func testKeepAliveNumericValuesBecomeNumbers() {
        // "-1" und "0" muss Ollama als ZAHL sehen — als String versteht es sie nicht.
        XCTAssertEqual(CleanupService.keepAliveValue("-1") as? Int, -1)
        XCTAssertEqual(CleanupService.keepAliveValue("0") as? Int, 0)
        XCTAssertEqual(CleanupService.keepAliveValue("7200") as? Int, 7200, "Sekunden bleiben Sekunden")
    }

    func testKeepAliveDurationsStayStrings() {
        XCTAssertEqual(CleanupService.keepAliveValue("2h") as? String, "2h")
        XCTAssertEqual(CleanupService.keepAliveValue("30m") as? String, "30m")
        XCTAssertEqual(CleanupService.keepAliveValue(" 20M ") as? String, "20m", "Leerzeichen/Großschreibung tolerieren")
    }

    func testKeepAliveGarbageFallsBackToFiniteValue() {
        // Ein Tippfehler in einer handgeschriebenen config.json darf weder den
        // Request zerschießen noch dauerhaft RAM belegen.
        XCTAssertEqual(CleanupService.keepAliveValue("für immer") as? String, "30m")
        XCTAssertEqual(CleanupService.keepAliveValue("") as? String, "30m")
    }

    func testPinsForeverOnlyForNegativeValues() {
        // Daran hängt der Minuten-Timer der App: Er darf NUR im Dauer-Modus laufen.
        XCTAssertTrue(CleanupService.pinsForever("-1"))
        XCTAssertFalse(CleanupService.pinsForever("2h"))
        XCTAssertFalse(CleanupService.pinsForever("0"), "sofort entladen ist nicht dauerhaft")
        XCTAssertFalse(CleanupService.pinsForever("unsinn"))
    }

    func testKeepAliveDefaultsAreTwoHoursPrimaryAndThirtyMinutesFallback() throws {
        // Bestands-Configs kennen das Feld nicht — sie müssen die neuen Defaults
        // bekommen und dürfen nicht auf einem leeren Wert landen.
        let json = #"{"cleanup": {"model": "test-modell", "fallbacks": [{"provider": "ollama"}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain[0].keepAlive, "2h", "primär: befristet, aber lang genug für eine Sitzung")
        XCTAssertEqual(chain[1].keepAlive, "30m", "Fallback belegt auf knappen Macs nur kurz RAM")
    }

    func testConfiguredKeepAliveReachesTheChain() throws {
        // Der im Dialog gewählte Wert muss beim primären Endpoint ankommen —
        // sonst schickt die App weiter den alten fest verdrahteten Wert.
        let json = #"{"cleanup": {"keepAlive": "-1", "fallbacks": [{"keepAlive": "5m"}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain[0].keepAlive, "-1")
        XCTAssertEqual(chain[1].keepAlive, "5m")
        XCTAssertTrue(CleanupService.pinsForever(chain[0].keepAlive))
    }

    func testCleanupChainOrderAndDefaults() throws {
        // Kette: entfernter Ollama-Rechner -> lokales Ollama -> Cloud-Anbieter.
        // Fehlende Felder in einem Fallback-Eintrag müssen Defaults bekommen.
        let json = """
        {"cleanup": {
            "ollamaURL": "http://192.168.1.50:11434",
            "fallbacks": [
                {"provider": "ollama"},
                {"provider": "openai", "remote": {"baseURL": "https://api.example.com/v1", "model": "cloud-modell"}}
            ]
        }}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain.count, 3)
        XCTAssertEqual(chain[0].ollamaURL, "http://192.168.1.50:11434")
        XCTAssertEqual(chain[1].ollamaURL, "http://127.0.0.1:11434", "fehlende Felder im Fallback = Defaults")
        XCTAssertEqual(chain[1].model, "gemma4:e4b-it-qat")
        XCTAssertEqual(chain[2].provider, "openai")
        XCTAssertEqual(chain[2].label, "cloud-modell @ https://api.example.com/v1")
    }

    func testPrimaryDirectRequestRetriesOnFreshConnection() async throws {
        // Ein geschlossener Loopback-Port prüft den Transport vor dem ersten
        // Frame. Der zweite Stream scheitert ebenfalls und es bleibt der Rohtext.
        var cleanup = Config.Cleanup()
        cleanup.ollamaURL = "http://127.0.0.1:1"
        let service = CleanupService(config: cleanup)
        let retryReported = LockedTestValue(false)
        service.onPrimaryRetry = { retryReported.update { $0 = true } }

        let result: CleanupService.Result? = await service.clean("roher text der bereinigt werden soll")
        XCTAssertTrue(retryReported.snapshot, "Zweitversuch muss gemeldet werden (Overlay-Transparenz)")
        XCTAssertEqual(result?.usedFallback, true)
    }

    func testStreamChunkParsing() throws {
        // Normales Häppchen
        var parsed = try CleanupService.streamChunk(fromLine: #"{"message":{"content":"Hallo "},"done":false}"#)
        XCTAssertEqual(parsed.chunk, "Hallo ")
        XCTAssertFalse(parsed.done)
        // Letzte Zeile: done + oft leerer content
        parsed = try CleanupService.streamChunk(fromLine: #"{"message":{"content":""},"done":true}"#)
        XCTAssertTrue(parsed.done)
        XCTAssertThrowsError(try CleanupService.streamChunk(fromLine: "kein json"))
        XCTAssertThrowsError(try CleanupService.streamChunk(fromLine: #"{"error":"Modell abgestürzt"}"#)) {
            guard case CleanupService.CleanupError.providerError(let detail) = $0 else {
                return XCTFail("Falscher Fehler: \($0)")
            }
            XCTAssertEqual(detail, "Modell abgestürzt")
        }
    }

    func testForeignErrorTextIsShortenedBeforeItReachesTheHistory() {
        // Diese Beschreibungen wandern über `fallbackReason` beziehungsweise
        // `errorMessage` dauerhaft in die Verlaufsdatei. Der Text kommt vom
        // Gegenüber — eine Fehlerseite eines Proxys oder ein beliebig langer
        // `error`-Wert im Stream darf den Verlauf nicht fluten. Geprüft werden
        // alle drei Wege gemeinsam, damit keiner die gemeinsame Grenze verliert.
        let flood = String(repeating: "x", count: 5000)
        let described: [String] = [
            CleanupService.CleanupError.serverError(body: flood).localizedDescription,
            CleanupService.CleanupError.providerError(flood).localizedDescription,
            WhisperClient.WhisperError.serverError(body: flood).localizedDescription,
        ]
        for text in described {
            XCTAssertEqual(text.filter { $0 == "x" }.count,
                           DiagnosticText.maxForeignCharacters,
                           "fremder Fehlertext muss gekürzt ankommen: \(text.prefix(40))")
        }
    }

    func testCleanupStreamRequiresExplicitCompletion() async {
        let raw = "das ist ein ausreichend langer roher text der niemals als halbe antwort verloren gehen darf"
        let partial = "Das ist ein ausreichend langer roher Text, der niemals als halbe Antwort"
        let transport = StubCleanupTransport(streams: [
            [#"{"message":{"content":"\#(partial)"},"done":false}"#],
            [#"{"message":{"content":"\#(partial)"},"done":false}"#],
        ])
        let service = CleanupService(config: Config.Cleanup(), transport: transport)

        let result = await service.clean(raw)

        // Fallback-Rohtext läuft durch die deterministische Nachstufe
        // (hier: nur Großschreibung am Satzanfang).
        XCTAssertEqual(result.text, "Das" + raw.dropFirst(3))
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(transport.streamCallCount, 2, "Direktpfad plus frische Verbindung")
        XCTAssertTrue(result.fallbackReason?.contains(L10n.text("core.cleanup.incomplete_stream")) ?? false)
    }

    func testCleanupStreamRetriesProviderErrorOnFreshConnection() async {
        let raw = "ähm das ist ein vollständiger test für einen provider fehler"
        let cleaned = "Das ist ein vollständiger Test für einen Provider-Fehler."
        let transport = StubCleanupTransport(streams: [
            [#"{"error":"Modell wird neu geladen"}"#],
            [
                #"{"message":{"content":"\#(cleaned)"},"done":false}"#,
                #"{"message":{"content":""},"done":true}"#,
            ],
        ])
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        let retryReported = LockedTestValue(false)
        service.onPrimaryRetry = { retryReported.update { $0 = true } }

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, cleaned)
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(retryReported.snapshot)
        XCTAssertEqual(transport.streamCallCount, 2)
    }

    func testCancelledCleanupDoesNotRetryOrUseFallback() async {
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let transport = StubCleanupTransport(outcomes: [.failure(error)])
            var config = Config.Cleanup()
            var fallback = Config.Cleanup.Endpoint()
            fallback.ollamaURL = "http://127.0.0.1:11435"
            fallback.model = "test"
            config.fallbacks = [fallback]
            let service = CleanupService(config: config, transport: transport)
            let retryReported = LockedTestValue(false)
            service.onPrimaryRetry = { retryReported.update { $0 = true } }
            _ = await service.clean("Dieser Text ist ein künstlicher Abbruchtest.")
            XCTAssertEqual(transport.streamCallCount, 1)
            XCTAssertEqual(transport.probeCallCount, 0)
            XCTAssertEqual(transport.normalCallCount, 0)
            XCTAssertFalse(retryReported.snapshot)
        }
    }

    func testCancelledIdleTimeoutProbeDoesNotRepeatOrUseFallback() async {
        let transport = StubCleanupTransport(outcomes: [.failure(URLError(.timedOut))], probeError: CancellationError())
        var config = Config.Cleanup()
        var fallback = Config.Cleanup.Endpoint()
        fallback.ollamaURL = "http://127.0.0.1:11435"
        config.fallbacks = [fallback]
        let service = CleanupService(config: config, transport: transport)
        _ = await service.clean("Dieser Text ist ein künstlicher Abbruchtest.")
        XCTAssertEqual(transport.probeCallCount, 1)
        XCTAssertEqual(transport.streamCallCount, 1)
        XCTAssertEqual(transport.normalCallCount, 0)
    }

    func testCancelledLiveBridgeDoesNotDecodeOrStartWhisper() async {
        let handlers = BridgeHandlers.live(config: Config(), version: "test")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await handlers.transcribe(Data())
                XCTFail("Stornierte Transkription lieferte Erfolg")
            } catch {
                XCTAssertTrue(error is CancellationError,
                              "Abbruch muss vor der Decoder-Fehlermeldung erfolgen")
            }
        }
        await task.value
    }

    func testCleanupFallsBackAfterTwoIncompletePrimaryStreams() async {
        let raw = "ähm das ist ein vollständiger test für einen echten fallback endpoint"
        let cleaned = "Das ist ein vollständiger Test für einen echten Fallback-Endpoint."
        var config = Config.Cleanup()
        config.fallbacks = [Config.Cleanup.Endpoint()]
        let incomplete = #"{"message":{"content":"Das ist ein vollständiger Test"},"done":false}"#
        let transport = StubCleanupTransport(
            streams: [[incomplete], [incomplete]], normalContent: cleaned
        )
        let service = CleanupService(config: config, transport: transport)
        let fallbackLabel = LockedTestValue<String?>(nil)
        service.onFallbackEndpoint = { label in fallbackLabel.update { $0 = label } }

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, cleaned)
        XCTAssertEqual(result.endpoint, config.fallbacks[0].label)
        XCTAssertEqual(fallbackLabel.snapshot, config.fallbacks[0].label)
        XCTAssertEqual(transport.probeCallCount, 1)
        XCTAssertEqual(transport.normalCallCount, 1)
    }

    func testPrimaryIdleTimeoutRetriesPatientlyWhileModelLoads() async {
        // Kaltstart des Bereinigungsmodells: Der Server nimmt die Verbindung an
        // und schweigt, bis das Leerlauf-Timeout des Streaming-Pfads zuschlaegt
        // (gemessen: 11,5 s Ladezeit gegen 10 s Geduld). Ein zweiter Stream mit
        // derselben kurzen Geduld liefe genauso ins Leere — erwartet wird die
        // geduldige Komplett-Antwort, nachdem die Probe den Server als lebendig
        // bestaetigt hat.
        let raw = "ähm das ist ein vollständiger test für ein kalt startendes modell"
        let cleaned = "Das ist ein vollständiger Test für ein kalt startendes Modell."
        let transport = StubCleanupTransport(
            outcomes: [.failure(URLError(.timedOut))], normalContent: cleaned
        )
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        let retryReported = LockedTestValue(false)
        service.onPrimaryRetry = { retryReported.update { $0 = true } }

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, cleaned)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.endpoint, Config.Cleanup().chain[0].label)
        XCTAssertTrue(retryReported.snapshot)
        XCTAssertEqual(transport.streamCallCount, 1,
                       "kein zweiter Stream mit derselben kurzen Geduld")
        XCTAssertEqual(transport.probeCallCount, 1, "eine Probe klaert: lebt der Server?")
        XCTAssertEqual(transport.normalCallCount, 1, "geduldige Komplett-Antwort")
    }

    func testPrimaryIdleTimeoutWithDeadServerSkipsSecondAttempt() async {
        // Gleiche Ausgangslage, aber der Server ist wirklich weg. Dann darf der
        // geduldige Versuch NICHT laufen: Er wuerde bis zu 120 s kosten, bevor
        // die Kette weiterzieht.
        let raw = "ähm das ist ein vollständiger test für einen wirklich toten endpoint"
        let transport = StubCleanupTransport(
            outcomes: [.failure(URLError(.timedOut))], probeSucceeds: false
        )
        let service = CleanupService(config: Config.Cleanup(), transport: transport)

        let result = await service.clean(raw)

        XCTAssertTrue(result.usedFallback)
        XCTAssertNil(result.endpoint)
        XCTAssertEqual(transport.streamCallCount, 1)
        XCTAssertEqual(transport.normalCallCount, 0,
                       "kein 120-s-Versuch gegen einen toten Server")
        XCTAssertTrue(result.fallbackReason?.contains("127.0.0.1:11434") ?? false,
                      "der tote Endpoint muss im Grund stehen: \(result.fallbackReason ?? "")")
    }

    func testEndpointCheckReportsReachabilityAndInstalledModel() async {
        // Die Pruefung fuer `doctor` liegt im Kern, damit Diagnose und
        // Bereinigung dieselbe Adresse, dieselbe Zeitgrenze und dieselbe
        // Namensregel benutzen.
        let endpoint = Config.Cleanup.Endpoint()

        let present = CleanupService(
            config: Config.Cleanup(),
            transport: StubCleanupTransport(outcomes: [], installedModels: [endpoint.model])
        )
        let checkedPresent = await present.checkOllamaEndpoint(endpoint)
        XCTAssertEqual(checkedPresent, .ready)

        // Ein eingestellter Name OHNE Tag meint bei Ollama `:latest` — nur dieser
        // eine Alias zaehlt zusaetzlich.
        var untagged = endpoint
        untagged.model = "gemma4"
        let tagged = CleanupService(
            config: Config.Cleanup(),
            transport: StubCleanupTransport(outcomes: [], installedModels: ["gemma4:latest"])
        )
        let checkedTagged = await tagged.checkOllamaEndpoint(untagged)
        XCTAssertEqual(checkedTagged, .ready, "ohne Tag meint Ollama :latest")

        // Ein beliebiger anderer Tag ist ein ANDERES Modell: Die Bereinigung
        // schickt spaeter "gemma4" und bekaeme "Modell fehlt" zurueck. Frueher
        // meldete `doctor` hier trotzdem gruen.
        let otherTag = CleanupService(
            config: Config.Cleanup(),
            transport: StubCleanupTransport(outcomes: [],
                                            installedModels: ["gemma4:e4b-it-qat"])
        )
        let checkedOtherTag = await otherTag.checkOllamaEndpoint(untagged)
        XCTAssertEqual(checkedOtherTag, .modelMissing,
                       "fremder Tag ist nicht dasselbe Modell")

        let other = CleanupService(
            config: Config.Cleanup(),
            transport: StubCleanupTransport(outcomes: [], installedModels: ["ganz-anderes-modell"])
        )
        let checkedOther = await other.checkOllamaEndpoint(endpoint)
        XCTAssertEqual(checkedOther, .modelMissing, "Server da, Modell nicht")

        let dead = CleanupService(
            config: Config.Cleanup(),
            transport: StubCleanupTransport(outcomes: [], probeSucceeds: false)
        )
        let checkedDead = await dead.checkOllamaEndpoint(endpoint)
        XCTAssertEqual(checkedDead, .unreachable)

        var brokenAddress = endpoint
        brokenAddress.ollamaURL = "kein server hier"
        let broken = CleanupService(
            config: Config.Cleanup(),
            transport: StubCleanupTransport(outcomes: [], installedModels: [endpoint.model])
        )
        let checkedBroken = await broken.checkOllamaEndpoint(brokenAddress)
        XCTAssertEqual(checkedBroken, .unreachable, "unbrauchbare Adresse darf nicht abstuerzen")

        var trailingSlash = endpoint
        trailingSlash.ollamaURL += "/"
        let checkedTrailingSlash = await present.checkOllamaEndpoint(trailingSlash)
        XCTAssertEqual(checkedTrailingSlash, .ready,
                       "ein abschließender Schrägstrich darf den API-Pfad nicht verdoppeln")

        for unusable in ["ftp://api.example.com", "file:///tmp/ollama"] {
            var invalid = endpoint
            invalid.ollamaURL = unusable
            let checkedInvalid = await present.checkOllamaEndpoint(invalid)
            XCTAssertEqual(checkedInvalid, .unreachable, "muss ablehnen: \(unusable)")
        }
    }

    func testModelNameMatchingAcceptsOnlyTheLatestAlias() {
        XCTAssertTrue(CleanupService.matchesModel("gemma4:e4b-it-qat", configured: "gemma4:e4b-it-qat"))
        // Ohne eigenen Tag meint Ollama `:latest` — dieser eine Alias zaehlt.
        XCTAssertTrue(CleanupService.matchesModel("gemma4:latest", configured: "gemma4"))
        // Jeder ANDERE Tag ist ein anderes Modell. Die Bereinigung schickt den
        // konfigurierten Namen unveraendert; ein Treffer hier waere eine falsche
        // Entwarnung in `doctor`.
        XCTAssertFalse(CleanupService.matchesModel("gemma4:e4b-it-qat", configured: "gemma4"))
        XCTAssertFalse(CleanupService.matchesModel("gemma4:e4b-it-qat:latest",
                                                   configured: "gemma4:e4b-it-qat"))
        // Nur der Doppelpunkt trennt Modell und Tag — ein laengerer Name ist ein
        // anderes Modell und darf nicht als vorhanden durchgehen.
        XCTAssertFalse(CleanupService.matchesModel("gemma4:e4b-it-qat-gross",
                                                   configured: "gemma4:e4b-it-qat"))
        XCTAssertFalse(CleanupService.matchesModel("gemma4", configured: "gemma4:e4b-it-qat"))
    }

    func testRemoteChatURLAcceptsOnlyCompleteHTTPAddresses() {
        var remote = Config.Cleanup.Remote()
        remote.model = "cloud-modell"

        remote.baseURL = "https://api.example.com/v1/"
        XCTAssertEqual(CleanupService.remoteChatURL(remote)?.absoluteString,
                       "https://api.example.com/v1/chat/completions",
                       "ein abschließender Schrägstrich darf keinen doppelten erzeugen")

        remote.baseURL = "http://127.0.0.1:8080/v1"
        XCTAssertEqual(CleanupService.remoteChatURL(remote)?.absoluteString,
                       "http://127.0.0.1:8080/v1/chat/completions")

        for unusable in [
            "api.example.com/v1",          // Schema fehlt
            "file:///tmp/v1",              // kein HTTP-Transport
            "ftp://api.example.com/v1",    // kein HTTP-Transport
            "https:///v1",                 // Host fehlt
            "https://api.example.com/v1?version=1", // Pfad würde in der Query landen
        ] {
            remote.baseURL = unusable
            XCTAssertNil(CleanupService.remoteChatURL(remote), "muss ablehnen: \(unusable)")
        }
    }

    func testStreamingCleanAgainstLocalOllamaIfAvailable() async throws {
        // Integrationstest des Streaming-Pfads gegen ein ECHTES lokales Ollama —
        // wird übersprungen, wenn keins läuft oder das Default-Modell fehlt
        // (Entwickler-Maschinen-Test, kein harter Bestandteil der Suite).
        let cleanup = Config.Cleanup()
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        guard let data = try? Data(contentsOf: URL(string: "\(cleanup.ollamaURL)/api/tags")!),
              let tags = try? JSONDecoder().decode(Tags.self, from: data),
              tags.models.contains(where: { $0.name == cleanup.model || $0.name.hasPrefix(cleanup.model + ":") }) else {
            throw XCTSkip("Kein lokales Ollama mit \(cleanup.model) — Streaming-Integrationstest übersprungen")
        }
        let service = CleanupService(config: cleanup)
        let result: CleanupService.Result? = await service.clean("also ähm das ist ist ein streaming test")
        // Der Live-Test prüft den Transport, nicht die schwankende Modellqualität:
        // Ändert das echte Modell ein Wort, muss die Worttreue-Sicherung ausdrücklich
        // auf Rohtext fallen. Ein gesetzter Endpoint beweist, dass der Stream mit
        // `done: true` vollständig ankam und erst danach geprüft wurde.
        XCTAssertEqual(result?.endpoint, cleanup.chain[0].label,
                       "Streaming-Transport muss abschließen: \(result?.fallbackReason ?? "")")
        XCTAssertFalse(result?.text.isEmpty ?? true)
    }

    func testCleanFallsBackToRawWhenAllEndpointsDead() async throws {
        // Zwei bewusst tote Endpoints (geschlossene lokale Ports): clean() darf
        // nicht hängen oder werfen, sondern muss den Rohtext zurückgeben und
        // beide Ausfälle im Fallback-Grund benennen.
        var cleanup = Config.Cleanup()
        cleanup.ollamaURL = "http://127.0.0.1:1"
        var fallback = Config.Cleanup.Endpoint()
        fallback.ollamaURL = "http://127.0.0.1:2"
        cleanup.fallbacks = [fallback]

        let raw = "das ist der rohe text"
        let result: CleanupService.Result? = await CleanupService(config: cleanup).clean(raw)
        // Auch ohne erreichbaren Endpoint greift die deterministische Nachstufe.
        XCTAssertEqual(result?.text, "Das" + raw.dropFirst(3))
        XCTAssertEqual(result?.usedFallback, true)
        XCTAssertNil(result?.endpoint)
        XCTAssertTrue(result?.fallbackReason?.contains("127.0.0.1:1") ?? false)
        XCTAssertTrue(result?.fallbackReason?.contains("127.0.0.1:2") ?? false)
    }
}

private final class StubCleanupTransport: CleanupTransport, @unchecked Sendable {
    /// Was der naechste Streaming-Aufruf liefern soll: die geplanten NDJSON-Zeilen
    /// oder einen Transportfehler (etwa das Leerlauf-Timeout des Primaerpfads).
    enum StreamOutcome {
        case frames([String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcomes: [StreamOutcome]
    private let normalContent: String
    private let probeSucceeds: Bool
    private let probeError: Error?
    /// Was `/api/tags` melden soll — die Modellliste des gestellten Servers.
    private let installedModels: [String]
    private(set) var streamCallCount = 0
    private(set) var probeCallCount = 0
    private(set) var normalCallCount = 0

    convenience init(streams: [[String]], normalContent: String = "") {
        self.init(outcomes: streams.map { .frames($0) }, normalContent: normalContent)
    }

    init(outcomes: [StreamOutcome], normalContent: String = "", probeSucceeds: Bool = true,
         installedModels: [String] = [], probeError: Error? = nil) {
        self.outcomes = outcomes
        self.normalContent = normalContent
        self.probeSucceeds = probeSucceeds
        self.probeError = probeError
        self.installedModels = installedModels
    }

    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        lock.withLock {
            if probing { probeCallCount += 1 } else { normalCallCount += 1 }
        }
        // Ein toter Server meldet sich auch bei der Probe nicht.
        if probing, let probeError { throw probeError }
        if probing, !probeSucceeds { throw URLError(.cannotConnectToHost) }
        let body: Data
        if request.url?.path == "/api/tags" {
            body = try JSONSerialization.data(withJSONObject: [
                "models": installedModels.map { ["name": $0] }
            ])
        } else if probing {
            body = Data(#"{"version":"test"}"#.utf8)
        } else {
            body = try JSONSerialization.data(withJSONObject: [
                "message": ["content": normalContent]
            ])
        }
        return (body, httpResponse(for: request, status: 200))
    }

    func streamLines(for request: URLRequest, freshConnection: Bool) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let outcome = lock.withLock {
            streamCallCount += 1
            return outcomes.isEmpty ? StreamOutcome.frames([]) : outcomes.removeFirst()
        }
        let frames: [String]
        switch outcome {
        case .failure(let error): throw error
        case .frames(let planned): frames = planned
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            frames.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return (stream, httpResponse(for: request, status: 200))
    }

    func sendWarmUp(_ request: URLRequest) {}

    private func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
