import Network
import Security
import CryptoKit
import XCTest
@testable import StillePostCore

/// Prüft den Listener über lokale TLS-Verbindungen ohne Whisper oder Ollama.
final class BridgeTests: XCTestCase {
    private static let identityNamespace = "stillepost.test.bridge." + UUID().uuidString
    private static let identity = Result { try BridgeIdentity.loadOrCreate(namespace: identityNamespace) }
    override class func tearDown() { try? BridgeIdentity.delete(namespace: identityNamespace); super.tearDown() }
    private static func serverIdentity() throws -> BridgeIdentity { try identity.get() }
    private var tlsParameters: NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            guard let pinned = try? Self.identity.get() else { complete(false); return }
            let checked = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(checked, SecPolicyCreateSSL(true, nil))
            SecTrustSetAnchorCertificates(checked, [pinned.certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(checked, true)
            SecTrustSetNetworkFetchAllowed(checked, false)
            guard let leaf = (SecTrustCopyCertificateChain(checked) as? [SecCertificate])?.first,
                  SecCertificateCopyData(leaf) as Data == SecCertificateCopyData(pinned.certificate) as Data else { complete(false); return }
            complete(SecTrustEvaluateWithError(checked, nil))
        }, DispatchQueue(label: "bridge-test.verify"))
        return NWParameters(tls: tls)
    }
    /// Steuerbare Serverarbeit für den echten Verbindungsabbruch-Test. Der Test
    /// wartet nicht nach Gefühl: Er schließt die TLS-Sitzung erst, nachdem die
    /// Transkription nachweislich begonnen hat, und gibt einen fehlerhaften alten
    /// Stand anschließend trotzdem sauber frei.
    private final class DisconnectWork: @unchecked Sendable {
        let started: XCTestExpectation
        let cancelled: XCTestExpectation
        private let lock = NSLock()
        private var released = false

        init(testCase: XCTestCase) {
            started = testCase.expectation(description: "Transkription gestartet")
            cancelled = testCase.expectation(description: "Transkription storniert")
        }

        func run() async throws -> String {
            started.fulfill()
            while true {
                if Task.isCancelled {
                    cancelled.fulfill()
                    throw CancellationError()
                }
                if isReleased { return "roher text" }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        private var isReleased: Bool {
            lock.lock()
            defer { lock.unlock() }
            return released
        }

        func release() {
            lock.lock()
            released = true
            lock.unlock()
        }
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
            let server = BridgeServer(config: bridge, router: router, identityProvider: Self.serverIdentity)
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
    private func exchange(port: Int, payload: Data, timeout: TimeInterval = 5, halfClose: Bool = false) -> String {
        final class Inbox: @unchecked Sendable {
            private let lock = NSLock()
            private var received = Data()
            func append(_ data: Data) { lock.lock(); received += data; lock.unlock() }
            var complete: Bool {
                lock.lock(); defer { lock.unlock() }
                guard let boundary = received.range(of: Data("\r\n\r\n".utf8)),
                      let header = String(data: received[..<boundary.lowerBound], encoding: .utf8),
                      let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) else { return false }
                return received.count - boundary.upperBound >= length
            }
            var text: String {
                lock.lock(); defer { lock.unlock() }
                return String(data: received, encoding: .utf8) ?? ""
            }
        }
        let inbox = Inbox()
        let closed = expectation(description: "Verbindung geschlossen")
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: tlsParameters
        )
        let clientQueue = DispatchQueue(label: "de.stillepost.test.client")
        @Sendable func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let data { inbox.append(data) }
                if inbox.complete || isComplete || error != nil {
                    connection.cancel()
                    closed.fulfill()
                } else {
                    readMore()
                }
            }
        }
        connection.start(queue: clientQueue)
        connection.send(content: payload, contentContext: halfClose ? .finalMessage : .defaultMessage, isComplete: true, completion: .contentProcessed { _ in })
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
        let server = BridgeServer(config: bridge, router: makeBridgeRouter(), identityProvider: Self.serverIdentity)
        XCTAssertThrowsError(try server.start(), "belegter Port darf keinen Erfolg melden")
        XCTAssertFalse(server.isRunning)
    }

    func testStartRequiresATokenBeforeOpeningThePort() {
        var bridge = Config.Bridge()
        bridge.port = 39999
        // `tokenStatus` fest vorgeben, damit der Test nicht vom echten
        // Schlüsselbund des ausführenden Macs abhängt.
        let server = BridgeServer(config: bridge, router: makeBridgeRouter(token: nil),
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
        let (server, port) = try startServer(router: makeBridgeRouter())
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
        let (server, port) = try startServer(router: makeBridgeRouter())
        defer { server.stop() }
        server.onSessionDeinitializedForTesting = { deallocated.fulfill() }
        let request = "GET /v1/health HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\n"
            + "Content-Length: 0\r\n\r\n"
        let response = exchange(port: port, payload: Data(request.utf8))
        XCTAssertTrue(response.contains("200"), "Antwort war: \(response)")
        wait(for: [deallocated], timeout: 5)
    }

    func testPlainHTTPIsRejectedByTLSListener() throws {
        let (server, port) = try startServer(router: makeBridgeRouter())
        defer { server.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return XCTFail("Socket fehlt") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(connected, 0)
        let payload = Data("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer richtig\r\n\r\n".utf8)
        _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &bytes, bytes.count, 0)
        let response = count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
        XCTAssertFalse(response.contains("HTTP/1.1"))
    }

    func testStopCancelsInFlightRequest() throws {
        let work = DisconnectWork(testCase: self)
        let (server, port) = try startServer(router: makeBridgeRouter(
            transcribe: { _ in try await work.run() }
        ))
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: tlsParameters
        )
        defer { work.release(); connection.cancel(); server.stop() }
        connection.start(queue: DispatchQueue(label: "de.stillepost.test.stop"))
        let request = "POST /v1/dictate HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\nContent-Length: 5\r\n\r\naudio"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        wait(for: [work.started], timeout: 5)
        server.stop()
        wait(for: [work.cancelled], timeout: 2)
        XCTAssertFalse(server.isRunning)
    }

    func testCredentialChangeCancelsWorkAndRestartsWithNewToken() throws {
        final class TokenState: @unchecked Sendable {
            let lock = NSLock(); private var stored = "richtig"
            var value: String { lock.lock(); defer { lock.unlock() }; return stored }
            func rotate() { lock.lock(); stored = "neu"; lock.unlock() }
        }
        let token = TokenState(), work = DisconnectWork(testCase: self)
        let handlers = BridgeHandlers(transcribe: { _ in try await work.run() },
            cleanup: { .init(text: $0, usedFallback: false, fallbackReason: nil, endpoint: "test") },
            cleanupEnabled: true, version: "test")
        let (server, port) = try startServer(router: BridgeRouter(handlers: handlers, maxBodyBytes: 1024, tokenProvider: { token.value }))
        let client = try connectedClient(port: port, label: "rotation")
        defer { work.release(); client.cancel(); server.stop() }
        client.send(content: Data("POST /v1/dictate HTTP/1.1\r\nAuthorization: Bearer richtig\r\nContent-Length: 5\r\n\r\naudio".utf8), completion: .contentProcessed { _ in })
        wait(for: [work.started], timeout: 5)
        token.rotate(); server.restartForCredentialChange()
        wait(for: [work.cancelled], timeout: 2)
        let deadline = Date().addingTimeInterval(5)
        while !server.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(server.isRunning)
        let old = exchange(port: port, payload: Data("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer richtig\r\n\r\n".utf8))
        XCTAssertTrue(old.hasPrefix("HTTP/1.1 401"))
        let new = exchange(port: port, payload: Data("GET /v1/health HTTP/1.1\r\nAuthorization: Bearer neu\r\n\r\n".utf8))
        XCTAssertTrue(new.hasPrefix("HTTP/1.1 200"))
    }

    func testClientTLSCloseCancelsInFlightRequest() throws {
        let work = DisconnectWork(testCase: self)
        let (server, port) = try startServer(router: makeBridgeRouter(
            transcribe: { _ in try await work.run() }
        ))
        defer { work.release(); server.stop() }
        let connection = try connectedClient(port: port, label: "cancel")
        let payload = Data(("POST /v1/dictate HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\nContent-Length: 5\r\n\r\naudio").utf8)
        connection.send(content: payload, completion: .contentProcessed { _ in })
        wait(for: [work.started], timeout: 5)
        connection.cancel()
        wait(for: [work.cancelled], timeout: 2)
    }

    func testAsyncStartDoesNotWaitForTokenLookup() {
        let completed = expectation(description: "Start abgeschlossen")
        let server = BridgeServer(config: Config.Bridge(), router: BridgeRouter(
            handlers: BridgeHandlers(transcribe: { _ in "" }, cleanup: { text in
                CleanupService.Result(text: text, usedFallback: false,
                                      fallbackReason: nil, endpoint: nil)
            }, cleanupEnabled: false, version: "test"), maxBodyBytes: 1024,
            tokenProvider: {
                Thread.sleep(forTimeInterval: 0.3)
                return nil
            }), tokenStatus: { .missing })
        let began = Date()
        server.start { result in
            if case .success = result { XCTFail("Start ohne Token") }
            completed.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.1)
        wait(for: [completed], timeout: 2)
        XCTAssertFalse(server.isRunning)
    }

    func testRotationDuringStartDeliversReplacementErrorToOriginalCallback() throws {
        let firstIdentity = expectation(description: "Erster Start wartet auf Identität")
        let returned = expectation(description: "Ersatzstart beantwortet den ersten Aufruf")
        let release = DispatchSemaphore(value: 0)
        let calls = LockedTestValue(0)
        struct ReplacementFailure: Error {}
        let identity = try Self.serverIdentity()
        var bridge = Config.Bridge()
        bridge.port = Int.random(in: 20_000...55_000)
        let server = BridgeServer(config: bridge, router: makeBridgeRouter(), identityProvider: {
            let call = calls.update { value in value += 1; return value }
            if call == 1 {
                firstIdentity.fulfill()
                _ = release.wait(timeout: .now() + 2)
                return identity
            }
            throw ReplacementFailure()
        })
        defer { server.stop() }
        server.start { result in
            switch result {
            case .success: XCTFail("Der ursprüngliche Start darf keinen Erfolg melden.")
            case .failure(let failure): XCTAssertTrue(failure is ReplacementFailure, "\(failure)")
            }
            returned.fulfill()
        }
        wait(for: [firstIdentity], timeout: 3)
        server.restartForCredentialChange()
        release.signal()
        wait(for: [returned], timeout: 5)
        XCTAssertEqual(calls.snapshot, 2)
        XCTAssertFalse(server.isRunning)
    }

    func testStopCompletionReleasesPortForReplacement() throws {
        let (old, port) = try startServer(router: makeBridgeRouter())
        let stopped = expectation(description: "Listener hat Port freigegeben")
        old.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        var config = Config.Bridge()
        config.port = port
        let replacement = BridgeServer(config: config, router: makeBridgeRouter(), identityProvider: Self.serverIdentity)
        defer { replacement.stop() }
        XCTAssertNoThrow(try replacement.start())
        XCTAssertTrue(replacement.isRunning)
    }

    func testRepeatedStopCallbacksAndRestartWaitForListenerCancellation() throws {
        let (server, _) = try startServer(router: makeBridgeRouter())
        let first = expectation(description: "Erster Stop bestätigt")
        let second = expectation(description: "Zweiter Stop bestätigt")
        let restarted = expectation(description: "Dieselbe Instanz erneut gestartet")
        server.stop { first.fulfill() }
        server.stop { second.fulfill() }
        server.start { result in
            if case .failure(let error) = result {
                XCTFail("Neustart nach Stop scheiterte: \(error)")
            }
            restarted.fulfill()
        }
        wait(for: [first, second, restarted], timeout: 5)
        XCTAssertTrue(server.isRunning)
        server.stop()
    }

    func testBufferLimitAdmitsAnExactlyMaximalRequest() throws {
        // Grenzwert: Kopf exakt am Kopf-Limit, Body exakt am Body-Limit. Diese
        // nach Parser-Vertrag gültige Anfrage muss unter den Puffer-Deckel des
        // Servers passen (früher fehlten die vier Trenner-Bytes `\r\n\r\n`).
        var bridge = Config.Bridge()
        bridge.maxRequestMegabytes = 1
        let server = BridgeServer(config: bridge, router: makeBridgeRouter(), identityProvider: Self.serverIdentity)
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

    func testHeaderAtTheLimitSurvivesAFragmentedSeparator() {
        // TCP zerteilt beliebig: Die vier Trenner-Bytes `\r\n\r\n` koennen
        // stueckweise ankommen. Ein Kopf von exakt maxHeaderBytes wurde dadurch
        // sporadisch als 400 verworfen — je nachdem, wie die Pakete fielen.
        var header = "POST /v1/dictate HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\n"
            + "Content-Length: 0\r\n"
            + "X-Pad: "
        header += String(repeating: "a", count: BridgeHTTP.maxHeaderBytes - header.utf8.count)
        XCTAssertEqual(header.utf8.count, BridgeHTTP.maxHeaderBytes)

        for prefix in ["", "\r", "\r\n", "\r\n\r"] {
            XCTAssertEqual(BridgeHTTP.parse(Data((header + prefix).utf8), maxBodyBytes: 1024),
                           .incomplete,
                           "angefangener Trenner ist noch kein Fehler")
        }
        guard case .complete = BridgeHTTP.parse(Data((header + "\r\n\r\n").utf8),
                                                maxBodyBytes: 1024) else {
            return XCTFail("der vollstaendige Kopf am Limit muss durchgehen")
        }
        // Andere Bytes jenseits des Kopf-Limits bleiben ein Fehler.
        guard case .failure = BridgeHTTP.parse(Data((header + "aaaa").utf8), maxBodyBytes: 1024) else {
            return XCTFail("ueberlanger Kopf ohne Trenner muss 400 ergeben")
        }
    }

    func testTotalBufferBudgetRefusesPiledUpBodies() throws {
        // Die Groessengrenze je Anfrage sagt nichts ueber ihre ANZAHL: Acht offene
        // Verbindungen durften bisher acht volle Bodys gleichzeitig puffern,
        // obwohl der Router hoechstens drei schwere Anfragen annimmt. Ueberlast
        // muss abgelehnt werden, BEVOR sie im Speicher liegt.
        let (server, port) = try startServer(router: makeBridgeRouter())
        defer { server.stop() }

        let announced = 1024 * 1024
        let chunkBytes = 900 * 1024
        // Drei Teil-Bodys passen ins Budget, der vierte nicht.
        XCTAssertGreaterThan(3 * chunkBytes + chunkBytes, server.maxBufferedBytesTotal)
        XCTAssertLessThan(3 * chunkBytes, server.maxBufferedBytesTotal)

        let refused = expectation(description: "eine Verbindung wird abgewiesen")
        refused.assertForOverFulfill = false
        var connections: [NWConnection] = []
        defer { connections.forEach { $0.cancel() } }

        for index in 0..<4 {
            let connection = NWConnection(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: tlsParameters
            )
            connections.append(connection)
            let ready = expectation(description: "Verbindung \(index) bereit")
            connection.stateUpdateHandler = { state in
                if case .ready = state { ready.fulfill() }
            }
            connection.start(queue: DispatchQueue(label: "de.stillepost.test.budget.\(index)"))
            wait(for: [ready], timeout: 5)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                if let data, String(data: data, encoding: .utf8)?.contains("503") == true {
                    refused.fulfill()
                }
            }

            let header = "POST /v1/dictate HTTP/1.1\r\n"
                + "Authorization: Bearer richtig\r\n"
                + "Content-Length: \(announced)\r\n\r\n"
            let sent = expectation(description: "Teil-Body \(index) raus")
            connection.send(content: Data(header.utf8) + Data(repeating: 0x61, count: chunkBytes),
                            completion: .contentProcessed { _ in sent.fulfill() })
            wait(for: [sent], timeout: 10)
        }

        wait(for: [refused], timeout: 10)
    }

    func testParsedBlockedRequestsStillConsumeTheTotalBufferBudget() throws {
        // Drei vollständige Requests sitzen in der Router-Pipeline. Ihr
        // Rohpuffer ist zwar freigegeben, die Router-Tasks halten die Bodys aber
        // weiterhin. Eine vierte, noch unvollständige Anfrage darf deshalb
        // nicht ein zweites gemeinsames Budget daneben aufbauen.
        let (server, port) = try startServer(router: makeBridgeRouter(
            transcribe: { _ in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                throw CancellationError()
            },
            maxBodyBytes: 1024 * 1024
        ))
        defer {
            server.stop()
        }

        let accepted = expectation(description: "drei Requests reserviert")
        accepted.expectedFulfillmentCount = 3
        server.onRequestAcceptedForTesting = { accepted.fulfill() }

        var connections: [NWConnection] = []
        defer { connections.forEach { $0.cancel() } }
        let bodyBytes = 900 * 1024
        for index in 0..<3 {
            let connection = try connectedClient(port: port, label: "parsed.\(index)")
            connections.append(connection)
            let header = "POST /v1/dictate?raw=1 HTTP/1.1\r\n"
                + "Authorization: Bearer richtig\r\n"
                + "Content-Length: \(bodyBytes)\r\n\r\n"
            let sent = expectation(description: "vollständiger Request \(index)")
            connection.send(
                content: Data(header.utf8) + Data(repeating: 0x61, count: bodyBytes),
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { _ in sent.fulfill() }
            )
            wait(for: [sent], timeout: 10)
        }
        wait(for: [accepted], timeout: 10)
        XCTAssertGreaterThan(server.bufferedBytesForTesting(), 3 * bodyBytes,
                             "geparste Bodys müssen weiterhin im Budget stehen")

        let fourth = try connectedClient(port: port, label: "parsed.fourth")
        connections.append(fourth)
        let refused = expectation(description: "zusätzlicher Teil-Body abgewiesen")
        server.onBufferBudgetRejectedForTesting = { refused.fulfill() }
        let announced = 1024 * 1024
        let remainingBudget = server.maxBufferedBytesTotal - server.bufferedBytesForTesting()
        XCTAssertGreaterThan(remainingBudget, 0)
        let fourthBodyBytes = remainingBudget + 64 * 1024
        XCTAssertLessThan(fourthBodyBytes, announced)
        let header = "POST /v1/dictate HTTP/1.1\r\n"
            + "Authorization: Bearer richtig\r\n"
            + "Content-Length: \(announced)\r\n\r\n"
        let sent = expectation(description: "zusätzlicher Teil-Body gesendet")
        fourth.send(
            content: Data(header.utf8) + Data(repeating: 0x62, count: fourthBodyBytes),
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { _ in sent.fulfill() }
        )
        wait(for: [sent, refused], timeout: 10)
    }

    private func connectedClient(port: Int, label: String) throws -> NWConnection {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: tlsParameters
        )
        let ready = expectation(description: "Client \(label) bereit")
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "de.stillepost.test.\(label)"))
        wait(for: [ready], timeout: 5)
        return connection
    }

    // MARK: - Protokoll

    func testAuthorizationFailureNamesTheReason() {
        // Im Protokoll stand früher nur „401“. Damit war nicht zu erkennen, ob der
        // Kurzbefehl auf dem iPhone überhaupt einen Authorization-Kopf schickt
        // oder ob bloß das Token nicht passt — genau diese Frage kostete bei der
        // Einrichtung die meiste Zeit.
        let router = makeBridgeRouter(token: "richtig")
        XCTAssertNil(router.authorizationFailure(bearerToken: "richtig"))
        XCTAssertEqual(router.authorizationFailure(bearerToken: nil), .noTokenSent)
        XCTAssertEqual(router.authorizationFailure(bearerToken: "falsch"), .tokenMismatch)

        let ohneToken = makeBridgeRouter(token: nil)
        XCTAssertEqual(ohneToken.authorizationFailure(bearerToken: "egal"), .noTokenOnThisMac)

        // Die HTTP-Antwort bleibt in allen Fällen dieselbe knappe 401 — die
        // Gegenseite soll aus ihr nichts über den Zustand des Macs lernen.
        for failure in [BridgeRouter.AuthFailure.noTokenSent, .tokenMismatch, .noTokenOnThisMac] {
            XCTAssertFalse(failure.logDescription.isEmpty)
        }
    }

    func testUntrustedLogFieldsStayOnOneLine() {
        XCTAssertEqual(
            BridgeServer.singleLineLogField(
                "/ok\n\u{001B}[31m\u{007F}\u{0085}\u{2028}\u{2029}"
            ),
            "/ok\\u{000A}\\u{001B}[31m\\u{007F}\\u{0085}\\u{2028}\\u{2029}"
        )
    }

    func testBridgeLogFileAppendsWithTimestampAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillepost-log-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bridge.log")

        // Kleine Grenze, damit der Test das Wegräumen ohne Megabyte auslöst.
        let log = BridgeLogFile(url: url, maxBytes: 120)
        log.append("POST /v1/dictate → 200")
        log.flush()

        let firstLine = try XCTUnwrap(String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(firstLine.contains("POST /v1/dictate → 200"))
        XCTAssertTrue(firstLine.hasPrefix("20"), "Zeile muss mit dem Datum beginnen: \(firstLine)")

        // Genug schreiben, dass die Grenze überschritten wird.
        for index in 0..<10 { log.append("Zeile \(index) mit etwas Fülltext für die Größe") }
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path),
                      "die volle Datei muss als .1 erhalten bleiben")
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 120 * 2, "die aktive Datei darf nicht unbegrenzt wachsen")
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
        let server = BridgeServer(config: bridge, router: makeBridgeRouter(token: nil),
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

    func testTokenCommandUsesOneLoadOutcomeAndNeverRegeneratesAfterReadFailure() throws {
        var loads = 0
        var regenerations = 0
        let reused = try BridgeToken.resolveForCommand(
            wantsNew: false,
            loadOutcome: { loads += 1; return .token("bestehend") },
            regenerate: { regenerations += 1; return "neu" }
        )
        XCTAssertEqual(reused.token, "bestehend")
        XCTAssertTrue(reused.reused)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(regenerations, 0)

        XCTAssertThrowsError(try BridgeToken.resolveForCommand(
            wantsNew: false,
            loadOutcome: { loads += 1; return .failed(errSecInteractionNotAllowed) },
            regenerate: { regenerations += 1; return "darf-nicht-entstehen" }
        ))
        XCTAssertEqual(loads, 2, "auch der Fehlerfall liest genau einmal")
        XCTAssertEqual(regenerations, 0, "Lesefehler darf kein Token ersetzen")

        let forced = try BridgeToken.resolveForCommand(
            wantsNew: true,
            loadOutcome: { XCTFail("--new braucht keinen vorherigen Lesezugriff"); return .missing },
            regenerate: { regenerations += 1; return "bewusst-neu" }
        )
        XCTAssertEqual(forced.token, "bewusst-neu")
        XCTAssertFalse(forced.reused)
        XCTAssertEqual(regenerations, 1)
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


}
