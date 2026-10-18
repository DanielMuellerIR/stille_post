import XCTest
@testable import StillePostClientCore

final class ClientTests: XCTestCase {
    func testLocalEndpointsAndClosedDefault() throws {
        let pin = String(repeating: "a", count: 64)
        for address in ["https://mac.local:8188", "https://MAC.local.:8188/", "https://10.2.3.4:8188", "https://192.168.1.9", "https://172.16.0.1", "https://[fd00::1]", "https://127.0.0.1", "https://[::1]"] {
            XCTAssertNoThrow(try BridgeConfiguration(address: address, fingerprint: pin).endpoint())
        }
        for address in ["http://mac.local", "https://example.org", "https://mac.local.example.org", "https://8.8.8.8", "https://172.32.0.1", "https://[2001:db8::1]", "https://mac.local/path", "https://mac.local?raw=1", "https://mac.local#fragment", "https://.local", "https://bad_name.local", "https://localhost", "https://mac.local:0", "https://user:password@mac.local"] {
            XCTAssertThrowsError(try BridgeConfiguration(address: address, fingerprint: pin).endpoint())
        }
        XCTAssertThrowsError(try BridgeConfiguration(address: "https://mac.local").endpoint()) {
            XCTAssertEqual($0 as? ClientFailure, .pairingRequired)
        }
        for pin in ["", "a", String(repeating: "A", count: 64), String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(try BridgeConfiguration(address: "https://mac.local", fingerprint: pin).endpoint())
        }
    }

    func testHealthAndAudioRequestsMatchExistingBridge() async throws {
        let transport = StubTransport(reply: HTTPReply(status: 200, body: Data(#"{"ok":true,"version":"dev","cleanup":true}"#.utf8)))
        let client = BridgeClient(transport: transport)
        let health = try await client.health(credentials())
        XCTAssertTrue(health.ok)
        let healthRequest = await transport.requests.last!
        XCTAssertEqual(healthRequest.httpMethod, "GET")
        XCTAssertEqual(healthRequest.url?.path, "/v1/health")
        XCTAssertEqual(healthRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertFalse(healthRequest.allowsCellularAccess)
        let url = try file(bytes: 128); defer { try? FileManager.default.removeItem(at: url) }
        await transport.setReply(HTTPReply(status: 200, body: Data(#"{"text":"Ein Test.","raw":"Ein Test","origin":"cleaned","sttSec":0.2,"cleanupSec":0.3}"#.utf8)))
        let result = try await client.dictate(Recording(url: url, duration: 2, bytes: 128), credentials: credentials(), progress: { _ in })
        XCTAssertEqual(result.text, "Ein Test.")
        let request = await transport.requests.last!
        XCTAssertEqual(request.url?.path, "/v1/dictate")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "128")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        let files = await transport.files
        XCTAssertEqual(files.compactMap { $0 }, [url])
    }

    func testNoAutomaticRetryAndSanitizedServerErrors() async throws {
        for (status, expected) in [(401, ClientFailure.unauthorized), (413, .recordingTooLarge), (503, .busy), (500, .serverFailed), (302, .redirected)] {
            let transport = StubTransport(reply: HTTPReply(status: status, body: Data(#"{"error":"sensitive fixture text"}"#.utf8)))
            do { _ = try await BridgeClient(transport: transport).health(credentials()); XCTFail("Erwarteter Fehler") }
            catch { XCTAssertEqual(error as? ClientFailure, expected) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testOversizedAudioAndInvalidTokenNeverReachTransport() async throws {
        let transport = StubTransport(reply: HTTPReply(status: 200, body: Data()))
        let client = BridgeClient(transport: transport)
        let url = try file(bytes: BridgeClient.maxAudioBytes + 1); defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await client.dictate(Recording(url: url, duration: 1, bytes: 1), credentials: credentials(), progress: { _ in })
            XCTFail("Dateigröße muss tatsächlich gelesen werden")
        } catch { XCTAssertEqual(error as? ClientFailure, .recordingTooLarge) }
        do { _ = try await client.health(BridgeCredentials(configuration: credentials().configuration, token: "bad\r\nheader")); XCTFail() }
        catch { XCTAssertEqual(error as? ClientFailure, .missingToken) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testResponseLimitAndMalformedReply() async throws {
        for (body, expected) in [(Data(repeating: 32, count: BridgeClient.maxResponseBytes + 1), ClientFailure.responseTooLarge), (Data("{}".utf8), .invalidResponse)] {
            let transport = StubTransport(reply: HTTPReply(status: 200, body: body))
            do { _ = try await BridgeClient(transport: transport).health(credentials()); XCTFail() }
            catch { XCTAssertEqual(error as? ClientFailure, expected) }
        }
    }

    func testUnfinishedRecordingNeverReachesTransport() async throws {
        let transport = StubTransport(reply: HTTPReply(status: 200, body: Data()))
        let url = try file(bytes: 128); defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await BridgeClient(transport: transport).dictate(
                Recording(url: url, duration: 0, bytes: 128), credentials: credentials(), progress: { _ in })
            XCTFail("Ein angelegter AAC-Header ist noch keine abgeschlossene Aufnahme")
        } catch { XCTAssertEqual(error as? ClientFailure, .noAudio) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    private func credentials() -> BridgeCredentials {
        BridgeCredentials(configuration: BridgeConfiguration(address: "https://mac.local:8188", fingerprint: String(repeating: "a", count: 64)), token: "fixture-token")
    }
    private func file(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }
}

actor StubTransport: BridgeTransport {
    var requests: [URLRequest] = []
    var files: [URL?] = []
    private var reply: HTTPReply
    init(reply: HTTPReply) { self.reply = reply }
    func setReply(_ reply: HTTPReply) { self.reply = reply }
    func perform(_ request: URLRequest, file: URL?, fingerprint: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPReply {
        requests.append(request); files.append(file); progress(1)
        return reply
    }
}
