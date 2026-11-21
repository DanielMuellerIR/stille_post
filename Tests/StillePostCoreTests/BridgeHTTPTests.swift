import XCTest
@testable import StillePostCore

final class BridgeHTTPTests: XCTestCase {
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

    func testRejectsControlCharactersInRequestLine() {
        for control in ["\n", "\u{001B}", "\u{007F}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let raw = "GET /v1/health\(control)FAKE HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
            guard case .failure(let response) = BridgeHTTP.parse(
                Data(raw.utf8), maxBodyBytes: 1024
            ) else {
                return XCTFail("Steuerzeichen in der Request-Line muss abgelehnt werden")
            }
            XCTAssertEqual(response.status, 400)
        }
    }

    // MARK: - Herkunft der Verbindung

    func testAcceptsOnlyHomeNetworkAddresses() {
        // Ohne eigene IPv6-Netze geprüft, damit das Ergebnis nicht davon abhängt,
        // in welchem Netz der Mac steckt, auf dem der Test gerade läuft.
        func isLocal(_ address: String) -> Bool {
            BridgePeer.isLocalNetwork(address, ownPrefixes: { [] })
        }
        for address in ["127.0.0.1", "192.168.1.57", "10.0.0.5", "172.20.1.1",
                        "169.254.3.4", "::1", "fe80::1cba:8c1a:1%en0", "fd00::1234",
                        "::ffff:192.168.1.5"] {
            XCTAssertTrue(isLocal(address), "\(address) ist Heimnetz")
        }
        // Öffentliche Adressen: Wenn die je hier ankommen, ist ein Port
        // versehentlich weitergeleitet.
        for address in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "2001:db8::1",
                        "2a02:8109:abcd::1", "", "nicht-ip"] {
            XCTAssertFalse(isLocal(address), "\(address) ist nicht Heimnetz")
        }
    }

    func testGlobalIPv6InDottedNotationIsNotHomeNetwork() {
        // "2a00:1234::192.168.1.1" ist eine gueltige Schreibweise einer GLOBALEN
        // IPv6-Adresse — die letzten vier Bytes duerfen als 1.2.3.4 geschrieben
        // werden. Wer nur "enthaelt einen Punkt" prueft, sieht darin eine private
        // IPv4-Adresse und laesst ein Geraet aus dem Internet durch.
        XCTAssertFalse(
            BridgePeer.isLocalNetwork("2a00:1234::192.168.1.1", ownPrefixes: { [] }),
            "globale IPv6-Adresse mit Punkt-Schreibweise gehoert nicht zum Heimnetz"
        )
        XCTAssertFalse(
            BridgePeer.isLocalNetwork("2a00:1234::10.0.0.5", ownPrefixes: { [] })
        )
        // Und die echte IPv4-in-IPv6-Form bleibt selbstverstaendlich Heimnetz —
        // jetzt in beiden Schreibweisen derselben Adresse. Frueher entschied der
        // Text: die Punkt-Form galt als Heimnetz, die gleichwertige Hex-Form nicht.
        XCTAssertTrue(
            BridgePeer.isLocalNetwork("::ffff:192.168.1.5", ownPrefixes: { [] })
        )
        XCTAssertTrue(
            BridgePeer.isLocalNetwork("::ffff:c0a8:105", ownPrefixes: { [] }),
            "dieselbe Adresse in Hex-Schreibweise"
        )
        // Eine eingebettete OEFFENTLICHE IPv4-Adresse bleibt draussen.
        XCTAssertFalse(
            BridgePeer.isLocalNetwork("::ffff:8.8.8.8", ownPrefixes: { [] })
        )
    }

    func testGlobalIPv6CountsAsHomeNetworkOnlyInsideAnOwnPrefix() {
        // Der Fall aus dem Alltag: Die FRITZ!Box gibt Mac und iPhone Adressen aus
        // demselben globalen /64. Zählt das nicht als Heimnetz, weist die Brücke
        // genau das iPhone ab, für das sie gebaut ist — und zwar lautlos, weil die
        // Verbindung schon vor dem Token abgeschnitten wird.
        let own = [IPv6Prefix("2001:db8:1:2::", bits: 64)!]

        XCTAssertTrue(BridgePeer.isLocalNetwork("2001:db8:1:2:abcd::9", ownPrefixes: { own }),
                      "gleiches /64 wie der Mac selbst: das ist das eigene Heimnetz")
        // Andere Schreibweise derselben Adresse — der Vergleich läuft über die
        // Bytes, nicht über den Text.
        XCTAssertTrue(BridgePeer.isLocalNetwork("2001:0db8:0001:0002:0000:0000:0000:0009",
                                                ownPrefixes: { own }))
        XCTAssertFalse(BridgePeer.isLocalNetwork("2001:db8:1:3::9", ownPrefixes: { own }),
                       "benachbartes /64 gehört nicht dazu")
        XCTAssertFalse(BridgePeer.isLocalNetwork("2a02:8109:abcd::1", ownPrefixes: { own }),
                       "fremdes Präfix aus dem Internet bleibt draußen")
        XCTAssertFalse(BridgePeer.isLocalNetwork("2001:db8:1:2:abcd::9", ownPrefixes: { [] }),
                       "ohne eigenes IPv6-Netz bleibt es bei den privaten Bereichen")
    }

    func testPrefixComparisonRespectsBitBoundaries() {
        // Präfixlängen sind nicht immer durch acht teilbar. Bei /63 unterscheiden
        // sich die beiden Netze erst im letzten Bit des vierten Blocks.
        let slash63 = IPv6Prefix("2001:db8:1:2::", bits: 63)!
        XCTAssertTrue(slash63.contains(IPv6Prefix.parse("2001:db8:1:3::1")!),
                      "…:3:: liegt noch im /63, das bei …:2:: beginnt")
        XCTAssertFalse(slash63.contains(IPv6Prefix.parse("2001:db8:1:4::1")!))

        // Netzmaske aus der Schnittstellenliste in eine Präfixlänge übersetzen.
        XCTAssertEqual(LocalNetworkInterfaces.leadingOneBits(
            [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8)), 64)
        XCTAssertEqual(LocalNetworkInterfaces.leadingOneBits(
            [0xFF, 0xFF, 0xFF, 0xFC] + [UInt8](repeating: 0, count: 12)), 30)
        XCTAssertEqual(LocalNetworkInterfaces.leadingOneBits(
            [UInt8](repeating: 0, count: 16)), 0)
    }
}
