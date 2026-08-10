import Network
import XCTest
@testable import StillePostCore

/// Verträge der Netzwerk-Brücke — ohne offenen Port, ohne whisper-server und ohne
/// Ollama. Geprüft wird genau das, was im Heimnetz schiefgehen darf und was nicht.
final class BridgeTests: XCTestCase {

    // MARK: - HTTP zerlegen

    func testParsesCompletePostRequest() throws {
        let raw = "POST /v1/cleanup?raw=1 HTTP/1.1\r\n"
            + "Host: mac.local:8188\r\n"
            + "Authorization: Bearer geheim123\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: 5\r\n\r\nhallo"
        guard case .complete(let request) = BridgeHTTP.parse(Data(raw.utf8), maxBodyBytes: 1024) else {
            return XCTFail("Anfrage sollte vollständig sein")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/cleanup")
        XCTAssertEqual(request.query["raw"], "1")
        XCTAssertEqual(request.bearerToken, "geheim123")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "hallo")
    }

    func testWaitsForMissingBodyBytes() {
        let raw = "POST /v1/cleanup HTTP/1.1\r\nContent-Length: 10\r\n\r\nhal"
        XCTAssertEqual(BridgeHTTP.parse(Data(raw.utf8), maxBodyBytes: 1024), .incomplete)
    }

    func testRejectsOversizedBodyBeforeReadingIt() {
        // Entscheidend: Die Ablehnung passiert schon anhand von Content-Length,
        // also bevor auch nur ein Byte Inhalt im Speicher liegt.
        let raw = "POST /v1/dictate HTTP/1.1\r\nContent-Length: 999999\r\n\r\n"
        guard case .failure(let response) = BridgeHTTP.parse(Data(raw.utf8), maxBodyBytes: 1024) else {
            return XCTFail("Zu große Anfrage muss abgelehnt werden")
        }
        XCTAssertEqual(response.status, 413)
    }

    func testRejectsChunkedEncodingHonestly() {
        let raw = "POST /v1/dictate HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        guard case .failure(let response) = BridgeHTTP.parse(Data(raw.utf8), maxBodyBytes: 1024) else {
            return XCTFail("Chunked ist nicht umgesetzt und muss abgelehnt werden")
        }
        XCTAssertEqual(response.status, 501)
    }

    func testHeaderFloodIsCutOff() {
        let flood = String(repeating: "X-Fill: 1234567890\r\n", count: 1000)
        let raw = "GET /v1/health HTTP/1.1\r\n" + flood
        guard case .failure(let response) = BridgeHTTP.parse(Data(raw.utf8), maxBodyBytes: 1024) else {
            return XCTFail("Endlose Kopfzeilen müssen abgebrochen werden")
        }
        XCTAssertEqual(response.status, 400)
    }

    func testProbeHeaderReadsTokenAndRouteBeforeBodyArrives() {
        // Grundlage der frühen Token-Prüfung: Sobald der Kopf da ist, liegen
        // Methode, Pfad und Token vor — ohne dass ein Byte Body angekommen ist.
        let raw = "POST /v1/dictate?raw=1 HTTP/1.1\r\n"
            + "Authorization: Bearer geheim123\r\n"
            + "Content-Length: 999999\r\n\r\nERSTE"
        XCTAssertEqual(BridgeHTTP.probeHeader(Data(raw.utf8)),
                       .complete(method: "POST", path: "/v1/dictate", bearerToken: "geheim123"))
        // Unvollständiger Kopf: weiterlesen, nichts bewerten.
        XCTAssertEqual(BridgeHTTP.probeHeader(Data("POST /v1/dictate HTTP/1.1\r\nAuthor".utf8)),
                       .incomplete)
    }

    // MARK: - Herkunft der Verbindung

    func testAcceptsOnlyHomeNetworkAddresses() {
        for address in ["127.0.0.1", "192.168.1.57", "10.0.0.5", "172.20.1.1",
                        "169.254.3.4", "::1", "fe80::1cba:8c1a:1%en0", "fd00::1234",
                        "::ffff:192.168.1.5"] {
            XCTAssertTrue(BridgePeer.isLocalNetwork(address), "\(address) ist Heimnetz")
        }
        // Öffentliche Adressen inklusive globaler IPv6-Präfixe der FRITZ!Box:
        // Wenn die je hier ankommen, ist ein Port versehentlich weitergeleitet.
        for address in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "2001:db8::1",
                        "2a02:8109:abcd::1", "", "nicht-ip"] {
            XCTAssertFalse(BridgePeer.isLocalNetwork(address), "\(address) ist nicht Heimnetz")
        }
    }

    // MARK: - Routen und Token

    /// Zähler, mit dem die Tests belegen, wie oft die Bereinigung wirklich lief.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeRouter(
        token: String? = "richtig",
        cleanupEnabled: Bool = true,
        transcribe: @escaping @Sendable (Data) async throws -> String = { _ in "roher text" },
        cleanupCounter: Counter? = nil
    ) -> BridgeRouter {
        let handlers = BridgeHandlers(
            transcribe: transcribe,
            cleanup: { raw in
                cleanupCounter?.increment()
                return CleanupService.Result(text: "Sauberer Text.", usedFallback: false,
                                             fallbackReason: nil, endpoint: "test")
            },
            cleanupEnabled: cleanupEnabled,
            version: "test"
        )
        return BridgeRouter(handlers: handlers, maxBodyBytes: 1024, tokenProvider: { token })
    }

    private func object(_ response: BridgeResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testWrongOrMissingTokenIsRejectedEverywhere() async throws {
        let router = makeRouter()
        for request in [
            BridgeRequest(method: "GET", path: "/v1/health"),
            BridgeRequest(method: "GET", path: "/v1/health", bearerToken: "falsch"),
            BridgeRequest(method: "POST", path: "/v1/dictate", bearerToken: "richtig2",
                          body: Data("audio".utf8)),
        ] {
            let response = await router.respond(to: request)
            XCTAssertEqual(response.status, 401, "\(request.path) ohne gültiges Token")
        }
    }

    func testMissingTokenOnTheMacBlocksEvenACorrectRequest() async {
        // Solange kein Token angelegt ist, ist die Brücke zu — auch für jemanden,
        // der zufällig einen leeren Token schickt.
        let router = makeRouter(token: nil)
        let response = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/health", bearerToken: ""
        ))
        XCTAssertEqual(response.status, 401)
    }

    func testHealthReportsVersionAndCleanupState() async throws {
        let router = makeRouter(cleanupEnabled: false)
        let response = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/health", bearerToken: "richtig"
        ))
        XCTAssertEqual(response.status, 200)
        let json = try object(response)
        XCTAssertEqual(json["version"] as? String, "test")
        XCTAssertEqual(json["cleanup"] as? Bool, false)
    }

    func testDictateRunsTranscriptionThenExactlyOneCleanup() async throws {
        let counter = Counter()
        let router = makeRouter(cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        let json = try object(response)
        XCTAssertEqual(json["text"] as? String, "Sauberer Text.")
        XCTAssertEqual(json["raw"] as? String, "roher text")
        // Die Architekturregel „genau eine Bereinigung über den ganzen Text“ gilt
        // auch auf diesem Weg.
        XCTAssertEqual(counter.count, 1)
    }

    func testRawParameterSkipsCleanup() async throws {
        let counter = Counter()
        let router = makeRouter(cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", query: ["raw": "1"],
            bearerToken: "richtig", body: Data("audio".utf8)
        ))
        let json = try object(response)
        XCTAssertEqual(json["text"] as? String, "roher text")
        XCTAssertEqual(counter.count, 0)
    }

    func testSilenceYieldsEmptyTextWithoutCleanup() async throws {
        let counter = Counter()
        let router = makeRouter(transcribe: { _ in "   " }, cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try object(response)["text"] as? String, "")
        XCTAssertEqual(counter.count, 0, "Auf Stille wird kein Modell bemüht")
    }

    func testTranscriptionFailureBecomesServerError() async throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "whisper-server nicht erreichbar" }
        }
        let router = makeRouter(transcribe: { _ in throw Boom() })
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio".utf8)
        ))
        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(try object(response)["error"] as? String, "whisper-server nicht erreichbar")
    }

    func testCleanupRouteTakesPlainTextAndReturnsCleanText() async throws {
        let counter = Counter()
        let router = makeRouter(cleanupCounter: counter)
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig",
            contentType: "text/plain; charset=utf-8", body: Data("äh also so".utf8)
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try object(response)["text"] as? String, "Sauberer Text.")
        XCTAssertEqual(counter.count, 1)
    }

    func testCleanupRouteRejectsEmptyAndNonUTF8Input() async throws {
        let router = makeRouter()
        let empty = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig", body: Data("  ".utf8)
        ))
        XCTAssertEqual(empty.status, 400)

        // 0xFF ist in UTF-8 nie gültig.
        let broken = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig",
            body: Data([0xFF, 0xFE, 0xFF])
        ))
        XCTAssertEqual(broken.status, 415)
    }

    func testRouterEnforcesTheBodyLimitItself() async throws {
        // Zweite Schutzschicht: Auch ein direkt erzeugter (nicht über
        // BridgeHTTP.parse gelaufener) Request unterliegt der Größengrenze.
        let router = makeRouter()  // maxBodyBytes: 1024
        let response = await router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/cleanup", bearerToken: "richtig",
            body: Data(repeating: 65, count: 2048)
        ))
        XCTAssertEqual(response.status, 413)
    }

    func testHeavyRoutesNeverOverlap() async throws {
        // Der Actor allein serialisiert NICHT: Jedes await auf die Handler gibt
        // seine Isolation frei. Zwei gleichzeitige Diktate müssen trotzdem
        // nacheinander laufen — sonst streiten sie sich um whisper-server und
        // Bereinigungsmodell.
        final class OverlapProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var active = 0
            private var peak = 0
            func enter() { lock.lock(); active += 1; peak = max(peak, active); lock.unlock() }
            func exit() { lock.lock(); active -= 1; lock.unlock() }
            var maxActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
        }
        let probe = OverlapProbe()
        let router = makeRouter(transcribe: { _ in
            probe.enter()
            try? await Task.sleep(nanoseconds: 100_000_000)
            probe.exit()
            return "roher text"
        })
        async let first = router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio-eins".utf8)))
        async let second = router.respond(to: BridgeRequest(
            method: "POST", path: "/v1/dictate", bearerToken: "richtig",
            body: Data("audio-zwei".utf8)))
        let responses = await [first, second]
        XCTAssertEqual(responses.map(\.status), [200, 200])
        XCTAssertEqual(probe.maxActive, 1, "Transkriptionen dürfen nie überlappen")
    }

    func testQueueLimitRejectsOverloadInsteadOfBufferingIt() async throws {
        // Die Serialisierung allein reicht nicht: Ohne Obergrenze hält jede
        // wartende Anfrage ihren vollständigen Body im Speicher, und ein
        // authentifizierter Client könnte beliebig viel Arbeit aufstauen (die
        // Größengrenze pro Anfrage sagt nichts über deren ANZAHL). Über der
        // Grenze muss die Brücke klar mit 503 ablehnen statt anzunehmen.
        let router = makeRouter(transcribe: { _ in
            try? await Task.sleep(nanoseconds: 400_000_000)
            return "roher text"
        })
        @Sendable func dictate() async -> BridgeResponse {
            await router.respond(to: BridgeRequest(
                method: "POST", path: "/v1/dictate", bearerToken: "richtig",
                body: Data("audio".utf8)
            ))
        }
        async let first = dictate()
        async let second = dictate()
        async let third = dictate()
        async let fourth = dictate()
        async let fifth = dictate()
        let statuses = await [first, second, third, fourth, fifth].map(\.status)
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 3,
                       "genau die Warteschlangentiefe darf durchlaufen")
        XCTAssertEqual(statuses.filter { $0 == 503 }.count, 2,
                       "der Rest wird abgelehnt, nicht gepuffert")
    }

    func testUnknownPathAndWrongMethod() async {
        let router = makeRouter()
        let unknown = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/alles", bearerToken: "richtig"
        ))
        XCTAssertEqual(unknown.status, 404)

        let wrongMethod = await router.respond(to: BridgeRequest(
            method: "GET", path: "/v1/dictate", bearerToken: "richtig"
        ))
        XCTAssertEqual(wrongMethod.status, 405)
    }

    // MARK: - Server über echte Loopback-Verbindungen

    /// Startet die Brücke auf einem zufälligen freien Port (mit Wiederholung,
    /// falls der gewürfelte Port belegt ist).
    private func startServer(router: BridgeRouter,
                             maxRequestMegabytes: Int = 1) throws -> (BridgeServer, Int) {
        var lastFailure: Error?
        for _ in 0..<10 {
            let port = Int.random(in: 30000..<60000)
            var bridge = Config.Bridge()
            bridge.enabled = true
            bridge.port = port
            bridge.maxRequestMegabytes = maxRequestMegabytes
            let server = BridgeServer(config: bridge, router: router)
            do {
                try server.start()
                return (server, port)
            } catch let error as BridgeServer.ServeError {
                // Nur ein fehlgeschlagenes Binden rechtfertigt einen neuen Port.
                // Ein fehlendes Token oder ein ungültiger Port ist eine echte
                // Regression und darf nicht als „Port belegt“ durchrutschen.
                guard case .listenFailed = error else { throw error }
                lastFailure = error
            }
        }
        // Zehnmal daneben ist kein Grund zum Überspringen: Dann ist der Start
        // kaputt (z. B. Listener meldet nie .ready) — der Test muss scheitern,
        // sonst sieht eine Regression aus wie „kein freier Port da“.
        throw lastFailure ?? XCTSkip("kein freier Testport gefunden")
    }

    /// Schickt rohe Bytes an die Brücke und sammelt die Antwort bis zum
    /// Verbindungsende (die Brücke sendet `Connection: close`).
    private func exchange(port: Int, payload: Data, timeout: TimeInterval = 5) -> String {
        final class Inbox: @unchecked Sendable {
            private let lock = NSLock()
            private var received = Data()
            func append(_ data: Data) { lock.lock(); received += data; lock.unlock() }
            var text: String {
                lock.lock(); defer { lock.unlock() }
                return String(data: received, encoding: .utf8) ?? ""
            }
        }
        let inbox = Inbox()
        let closed = expectation(description: "Verbindung geschlossen")
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp
        )
        let clientQueue = DispatchQueue(label: "de.stillepost.test.client")
        @Sendable func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let data { inbox.append(data) }
                if isComplete || error != nil {
                    connection.cancel()
                    closed.fulfill()
                } else {
                    readMore()
                }
            }
        }
        connection.start(queue: clientQueue)
        connection.send(content: payload, completion: .contentProcessed { _ in })
        readMore()
        wait(for: [closed], timeout: timeout)
        return inbox.text
    }

    func testStartFailsWhenThePortIsAlreadyTaken() throws {
        // Port mit einem rohen Socket belegen (ohne SO_REUSEPORT) — die Brücke
        // muss den asynchron gemeldeten Bindefehler an start() durchreichen,
        // statt „gestartet“ zu melden, obwohl kein Port lauscht.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        address.sin_port = 0  // Kernel wählt einen freien Port
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        XCTAssertEqual(bound, 0)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        XCTAssertEqual(listen(fd, 1), 0)
        let takenPort = Int(UInt16(bigEndian: address.sin_port))

        var bridge = Config.Bridge()
        bridge.port = takenPort
        let server = BridgeServer(config: bridge, router: makeRouter())
        XCTAssertThrowsError(try server.start(), "belegter Port darf keinen Erfolg melden")
        XCTAssertFalse(server.isRunning)
    }

    func testStartRequiresATokenBeforeOpeningThePort() {
        var bridge = Config.Bridge()
        bridge.port = 39999
        // `tokenStatus` fest vorgeben, damit der Test nicht vom echten
        // Schlüsselbund des ausführenden Macs abhängt.
        let server = BridgeServer(config: bridge, router: makeRouter(token: nil),
                                  tokenStatus: { .missing })
        XCTAssertThrowsError(try server.start()) { error in
            guard case BridgeServer.ServeError.noToken = error else {
                return XCTFail("fehlendes Token muss als solches gemeldet werden: \(error)")
            }
        }
        XCTAssertFalse(server.isRunning)
    }

    func testInvalidTokenIsRejectedAfterTheHeaderBeforeTheBody() throws {
        // Speicherdruck-Schutz: Ein falsches Token wird direkt nach dem Kopf
        // abgewiesen — die Brücke wartet NICHT erst auf den angekündigten
        // (großen) Body. Der Test schickt bewusst nur den Kopf.
        let (server, port) = try startServer(router: makeRouter())
        defer { server.stop() }
        let headerOnly = "POST /v1/dictate HTTP/1.1\r\n"
            + "Authorization: Bearer falsch\r\n"
            + "Content-Length: 500000\r\n\r\n"
        let response = exchange(port: port, payload: Data(headerOnly.utf8))
        XCTAssertTrue(response.contains("401"), "Antwort war: \(response)")
    }

    func testSessionsAreDeallocatedAfterTheConnectionCloses() throws {
        // Beweis, dass der Referenzzyklus (State-Handler → Session → Verbindung)
        // gelöst ist: Nach einer abgeschlossenen Anfrage muss die Session samt
        // Puffer wieder freigegeben werden.
        let deallocated = expectation(description: "Session freigegeben")
        deallocated.assertForOverFulfill = false
        BridgeServer.sessionDeinitHook = { deallocated.fulfill() }
        defer { BridgeServer.sessionDeinitHook = nil }

        let (server, port) = try startServer(router: makeRouter())
        defer { server.stop() }
        let request = "GET /v1/health HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\n"
            + "Content-Length: 0\r\n\r\n"
        let response = exchange(port: port, payload: Data(request.utf8))
        XCTAssertTrue(response.contains("200"), "Antwort war: \(response)")
        wait(for: [deallocated], timeout: 5)
    }

    func testBufferLimitAdmitsAnExactlyMaximalRequest() throws {
        // Grenzwert: Kopf exakt am Kopf-Limit, Body exakt am Body-Limit. Diese
        // nach Parser-Vertrag gültige Anfrage muss unter den Puffer-Deckel des
        // Servers passen (früher fehlten die vier Trenner-Bytes `\r\n\r\n`).
        var bridge = Config.Bridge()
        bridge.maxRequestMegabytes = 1
        let server = BridgeServer(config: bridge, router: makeRouter())
        let maxBody = server.maxBodyBytes

        var header = "POST /v1/dictate HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\n"
            + "Content-Length: \(maxBody)\r\n"
            + "X-Pad: "
        header += String(repeating: "a", count: BridgeHTTP.maxHeaderBytes - header.utf8.count)
        XCTAssertEqual(header.utf8.count, BridgeHTTP.maxHeaderBytes)

        let request = Data(header.utf8) + Data("\r\n\r\n".utf8)
            + Data(repeating: 0, count: maxBody)
        XCTAssertEqual(request.count, server.maxBufferBytes,
                       "maximale gültige Anfrage muss exakt unter den Deckel passen")
        guard case .complete = BridgeHTTP.parse(request, maxBodyBytes: maxBody) else {
            return XCTFail("exakt maximale Anfrage muss vollständig zerlegbar sein")
        }
    }

    // MARK: - Token-Vergleich

    func testTokenComparisonRejectsPrefixesAndEmptyValues() {
        let token = BridgeToken.generate()
        XCTAssertTrue(BridgeToken.matches(token, expected: token))
        XCTAssertFalse(BridgeToken.matches(String(token.dropLast()), expected: token))
        XCTAssertFalse(BridgeToken.matches(token + "x", expected: token))
        XCTAssertFalse(BridgeToken.matches("", expected: token))
        XCTAssertFalse(BridgeToken.matches(token, expected: ""))
    }

    func testTokenReadSeparatesMissingEntryFromKeychainFailure() {
        // Beides ergab früher `nil` und damit dieselbe Meldung „kein Token
        // vorhanden“. Ein gesperrter oder verweigernder Schlüsselbund schickte
        // den Nutzer damit zum Anlegen eines neuen Tokens — obwohl das alte
        // vielleicht noch da ist und ein neues alle Geräte aussperren würde.
        let missing = BridgeToken.loadOutcome(
            environment: [:], copyMatching: { _, _ in errSecItemNotFound }
        )
        XCTAssertEqual(missing, .missing)

        let locked = BridgeToken.loadOutcome(
            environment: [:], copyMatching: { _, _ in errSecInteractionNotAllowed }
        )
        XCTAssertEqual(locked, .failed(errSecInteractionNotAllowed))

        // Eintrag vorhanden, aber leer: kaputt, nicht „noch keins angelegt“.
        let empty = BridgeToken.loadOutcome(environment: [:], copyMatching: { _, result in
            result?.pointee = Data() as CFTypeRef
            return errSecSuccess
        })
        XCTAssertEqual(empty, .failed(errSecDecode))

        let found = BridgeToken.loadOutcome(environment: [:], copyMatching: { _, result in
            result?.pointee = Data("geheim".utf8) as CFTypeRef
            return errSecSuccess
        })
        XCTAssertEqual(found, .token("geheim"))

        // Die Umgebungsvariable hat weiterhin Vorrang und fasst den
        // Schlüsselbund gar nicht erst an.
        let fromEnv = BridgeToken.loadOutcome(
            environment: [BridgeToken.environmentVariable: "aus-der-umgebung"],
            copyMatching: { _, _ in XCTFail("Schlüsselbund darf hier nicht gelesen werden")
                            return errSecItemNotFound }
        )
        XCTAssertEqual(fromEnv, .token("aus-der-umgebung"))
    }

    func testStartNamesKeychainFailureInsteadOfSuggestingANewToken() {
        var bridge = Config.Bridge()
        bridge.port = 39998
        let server = BridgeServer(config: bridge, router: makeRouter(token: nil),
                                  tokenStatus: { .failed(errSecInteractionNotAllowed) })
        XCTAssertThrowsError(try server.start()) { error in
            guard case BridgeServer.ServeError.keychainUnavailable(let status) = error else {
                return XCTFail("Lesefehler muss als solcher gemeldet werden: \(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
            let message = error.localizedDescription
            XCTAssertNotEqual(message, L10n.text("core.bridge.no_token"))
            XCTAssertTrue(message.contains(String(errSecInteractionNotAllowed)),
                          "Der Schlüsselbund-Status gehört in die Meldung: \(message)")
        }
        XCTAssertFalse(server.isRunning)
    }

    func testKeychainStoreUpdatesInsteadOfDeleteThenAdd() {
        // Der frühere Ablauf „löschen, dann anlegen“ verlor bei einem
        // fehlgeschlagenen Anlegen den alten, gültigen Token — alle
        // eingerichteten Geräte wären ausgesperrt. Jetzt gilt: vorhandene
        // Einträge aktualisieren, nur fehlende anlegen, und jeder Fehler lässt
        // den bisherigen Wert unangetastet.
        final class Recorder {
            var updates = 0
            var adds = 0
        }

        // Vorhandener Eintrag: nur aktualisieren, nichts anlegen.
        let existing = Recorder()
        XCTAssertEqual(KeychainUpsert.store(
            service: "test", value: Data("neu".utf8),
            update: { _, _ in existing.updates += 1; return errSecSuccess },
            add: { _ in existing.adds += 1; return errSecSuccess }
        ), errSecSuccess)
        XCTAssertEqual([existing.updates, existing.adds], [1, 0])

        // Fehlender Eintrag: Update meldet notFound, dann wird angelegt.
        let missing = Recorder()
        XCTAssertEqual(KeychainUpsert.store(
            service: "test", value: Data("neu".utf8),
            update: { _, _ in missing.updates += 1; return errSecItemNotFound },
            add: { _ in missing.adds += 1; return errSecSuccess }
        ), errSecSuccess)
        XCTAssertEqual([missing.updates, missing.adds], [1, 1])

        // Fehlgeschlagenes Update wird durchgereicht — ohne Anlege-Versuch,
        // und (anders als früher) ohne dass je etwas gelöscht wurde.
        let failing = Recorder()
        XCTAssertEqual(KeychainUpsert.store(
            service: "test", value: Data("neu".utf8),
            update: { _, _ in errSecInteractionNotAllowed },
            add: { _ in failing.adds += 1; return errSecSuccess }
        ), errSecInteractionNotAllowed)
        XCTAssertEqual(failing.adds, 0)
    }

    func testGeneratedTokensAreLongAndUnique() {
        let first = BridgeToken.generate()
        let second = BridgeToken.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.count, 40)
        // URL-sicher: darf ohne Kodierung in einen Kopf oder eine Datei geschrieben werden.
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    // MARK: - Konfiguration

    func testBridgeIsOffByDefaultAndValidatesItsRanges() throws {
        var config = Config()
        XCTAssertFalse(config.bridge.enabled, "Ein offener Port darf keine Voreinstellung sein")
        XCTAssertNoThrow(try config.validate())

        config.bridge.port = 80          // unter 1024: bräuchte Root-Rechte
        XCTAssertThrowsError(try config.validate())
        config.bridge.port = 8188
        config.bridge.maxRequestMegabytes = 0
        XCTAssertThrowsError(try config.validate())
    }

    func testBrokenBridgeValuesFallBackFieldByField() throws {
        let json = """
        {"bridge": {"enabled": true, "port": 70000, "maxRequestMegabytes": 40}}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(config.bridge.enabled, "gültige Nachbarfelder bleiben erhalten")
        XCTAssertEqual(config.bridge.port, Config.Bridge().port, "kaputter Port -> Default")
        XCTAssertEqual(config.bridge.maxRequestMegabytes, 40)
    }

    // MARK: - Audio

    func testAudioFormatIsRecognizedFromTheFirstBytes() {
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("RIFF....WAVEfmt ".utf8)), "wav")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("....ftypM4A ".utf8)), "m4a")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("OggS".utf8)), "ogg")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("ID3".utf8)), "mp3")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data([0xFF, 0xFB, 0x90])), "mp3")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("irgendwas".utf8)), "audio")
    }

    func testDecoderTurnsWavIntoSixteenKilohertzMono() throws {
        // Eine Sekunde Sinuston bei 44,1 kHz -> muss auf 16 kHz mono landen.
        let sampleRate = 44100
        var samples = [Float]()
        for index in 0..<sampleRate {
            samples.append(sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.5)
        }
        let wav = wavData(from: samples, sampleRate: sampleRate)
        let decoded = try AudioDecoder.samples16kMono(from: wav)
        // Rundungen des Umwandlers zulassen, aber die Größenordnung festnageln.
        XCTAssertEqual(Double(decoded.count), 16000, accuracy: 500)
        XCTAssertTrue(decoded.contains { abs($0) > 0.1 }, "Signal darf nicht verschwinden")
    }

    func testDecoderEnforcesTheLengthLimit() throws {
        // Zwei Sekunden Audio gegen ein (nur im Test) auf eine Sekunde gesetztes
        // Limit: Die Grenze muss greifen, bevor der Speicher verbraucht ist.
        let sampleRate = 16000
        let samples = [Float](repeating: 0.25, count: sampleRate * 2)
        let wav = wavData(from: samples, sampleRate: sampleRate)
        XCTAssertThrowsError(try AudioDecoder.samples16kMono(from: wav,
                                                             maxSampleCount: sampleRate)) { error in
            guard case AudioDecoder.DecodeError.tooLong = error else {
                return XCTFail("erwartet tooLong, war: \(error)")
            }
        }
        // Dieselbe Datei ohne Test-Limit bleibt gültig.
        XCTAssertNoThrow(try AudioDecoder.samples16kMono(from: wav))
    }

    func testDecoderTreatsMidFileReadErrorAsErrorNotAsShortSuccess() throws {
        // Kaputte Aufnahme: Ein m4a, dessen hintere Audiodaten zerstört sind,
        // liefert erst gültige Frames und dann einen Lesefehler mitten in der
        // Datei. Das darf KEIN stiller Teilerfolg werden — sonst würde
        // abgeschnittenes Audio kommentarlos transkribiert und als Erfolg
        // gemeldet (frühere Lücke: Lesefehler galten pauschal als Dateiende).
        let converter = URL(fileURLWithPath: "/usr/bin/afconvert")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: converter.path),
                          "afconvert nicht verfügbar")

        // 1 s Sinuston als WAV, mit afconvert nach AAC/m4a gewandelt.
        let sampleRate = 44100
        var samples = [Float]()
        for index in 0..<sampleRate {
            samples.append(sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.5)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillepost-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("ton.wav")
        let m4aURL = directory.appendingPathComponent("ton.m4a")
        try wavData(from: samples, sampleRate: sampleRate).write(to: wavURL)
        let convert = Process()
        convert.executableURL = converter
        convert.arguments = ["-f", "m4af", "-d", "aac", wavURL.path, m4aURL.path]
        try convert.run()
        convert.waitUntilExit()
        try XCTSkipUnless(convert.terminationStatus == 0, "afconvert fehlgeschlagen")

        // Erst der Gegenbeweis: Die unveränderte Datei muss sauber dekodieren.
        // Ohne ihn belegt der Test unten nur, dass irgendetwas an der Datei
        // kaputt ist — nicht, dass der Lesefehler-Pfad greift.
        let intact = try Data(contentsOf: m4aURL)
        XCTAssertFalse(try AudioDecoder.samples16kMono(from: intact).isEmpty)

        // Hinteres Drittel der Audiodaten zerstören — aber nur INNERHALB des
        // mdat-Atoms. Bis ans Dateiende zu schreiben träfe auch das dahinter
        // liegende moov-Atom mit der Pakettabelle; dann scheiterte schon das
        // Öffnen, und der zu prüfende Fehlerpfad MITTEN im Lesen käme nie dran.
        var m4a = intact
        let tag = try XCTUnwrap(m4a.range(of: Data("mdat".utf8)))
        try XCTSkipUnless(tag.lowerBound >= 4, "mdat ohne vorangestelltes Größenfeld")
        // Vor dem Atomnamen stehen vier Bytes Atomgröße (Big Endian).
        let sizeField = tag.lowerBound - 4
        let atomSize = Int(m4a[sizeField..<tag.lowerBound]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        try XCTSkipUnless(atomSize > 8 && sizeField + atomSize <= m4a.count,
                          "unerwartete mdat-Größe (64-Bit-Variante?)")
        let payload = tag.upperBound..<(sizeField + atomSize)
        for index in (payload.lowerBound + payload.count * 2 / 3)..<payload.upperBound {
            m4a[index] = 0xAA
        }

        XCTAssertThrowsError(try AudioDecoder.samples16kMono(from: m4a)) { error in
            guard case AudioDecoder.DecodeError.unsupported = error else {
                return XCTFail("erwartet unsupported, war: \(error)")
            }
        }
    }

    func testDecoderRejectsGarbageAndEmptyInput() {
        XCTAssertThrowsError(try AudioDecoder.samples16kMono(from: Data()))
        XCTAssertThrowsError(try AudioDecoder.samples16kMono(
            from: Data(repeating: 0x41, count: 4096)
        ))
    }

    /// Minimaler WAV-Schreiber für den Test (16 Bit, mono, freie Abtastrate).
    /// Der Kern-Schreiber `WavCodec` kann nur 16 kHz — hier brauchen wir aber
    /// bewusst eine andere Rate, damit die Umrechnung überhaupt etwas tut.
    private func wavData(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func append32(_ value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)) }
        func append16(_ value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)) }
        append("RIFF"); append32(36 + byteCount); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(byteCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.append(contentsOf: withUnsafeBytes(of: Int16(clamped * 32767).littleEndian, Array.init))
        }
        return data
    }
}
