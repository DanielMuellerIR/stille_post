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

    // MARK: - Herkunft der Verbindung

    func testAcceptsOnlyHomeNetworkAddresses() {
        for address in ["127.0.0.1", "192.168.66.57", "10.0.0.5", "172.20.1.1",
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

    // MARK: - Token-Vergleich

    func testTokenComparisonRejectsPrefixesAndEmptyValues() {
        let token = BridgeToken.generate()
        XCTAssertTrue(BridgeToken.matches(token, expected: token))
        XCTAssertFalse(BridgeToken.matches(String(token.dropLast()), expected: token))
        XCTAssertFalse(BridgeToken.matches(token + "x", expected: token))
        XCTAssertFalse(BridgeToken.matches("", expected: token))
        XCTAssertFalse(BridgeToken.matches(token, expected: ""))
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
