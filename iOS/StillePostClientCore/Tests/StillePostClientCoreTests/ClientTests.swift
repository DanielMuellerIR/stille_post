import XCTest
@testable import StillePostClientCore

final class ClientTests: XCTestCase {
    func testLocalEndpointsAndClosedDefault() throws {
        for address in ["http://mac.local:8188", "http://MAC.local.:8188/", "http://10.2.3.4:8188", "http://192.168.1.9", "http://172.16.0.1", "http://[fd00::1]", "http://127.0.0.1", "http://[::1]"] {
            XCTAssertNoThrow(try BridgeConfiguration(address: address, allowInsecureDevelopment: true).endpoint(), address)
        }
        for address in ["https://mac.local", "http://example.org", "http://mac.local.example.org", "http://8.8.8.8", "http://172.32.0.1", "http://[2001:db8::1]", "http://mac.local/path", "http://mac.local?raw=1", "http://mac.local#fragment", "http://.local", "http://bad_name.local", "http://localhost", "http://mac.local:0"] {
            XCTAssertThrowsError(try BridgeConfiguration(address: address, allowInsecureDevelopment: true).endpoint(), address)
        }
        var withCredentials = URLComponents(string: "http://mac.local")!
        withCredentials.user = "fixture-user"; withCredentials.password = "fixture-password"
        XCTAssertThrowsError(try BridgeConfiguration(address: withCredentials.string!, allowInsecureDevelopment: true).endpoint())
        XCTAssertThrowsError(try BridgeConfiguration(address: "http://mac.local").endpoint()) {
            XCTAssertEqual($0 as? ClientFailure, .insecureDisabled)
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
        BridgeCredentials(configuration: BridgeConfiguration(address: "http://mac.local:8188", allowInsecureDevelopment: true), token: "fixture-token")
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
    func perform(_ request: URLRequest, file: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPReply {
        requests.append(request); files.append(file); progress(1)
        return reply
    }
}
