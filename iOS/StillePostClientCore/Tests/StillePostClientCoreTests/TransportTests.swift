import Network
import Security
import XCTest
@testable import StillePostClientCore

final class TransportTests: XCTestCase {
    func testTextCleanupSendsOnlyUTF8OverPinnedTLS() async throws {
        let body = Data(#"{"text":"Keine 13 Kopien.","origin":"cleaned"}"#.utf8)
        let server = try HTTPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
        defer { server.stop() }
        let text = "Keine dreizehn Kopien für morgen."
        let credentials = BridgeCredentials(configuration: BridgeConfiguration(address: server.address, fingerprint: server.identity.fingerprint), token: "fixture-token")
        _ = try await BridgeClient().cleanup(text, credentials: credentials)
        let request = server.received()
        XCTAssertTrue(request.starts(with: Data("POST /v1/cleanup HTTP/1.1".utf8)))
        let boundary = try XCTUnwrap(request.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(request.suffix(from: boundary.upperBound), Data(text.utf8))
    }

    func testRealUploadWithContentLengthAndBoundedReply() async throws {
        let body = Data(#"{"text":"Network test."}"#.utf8)
        let server = try HTTPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body)
        defer { server.stop() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 256_000).write(to: url)
        let credentials = BridgeCredentials(configuration: BridgeConfiguration(address: server.address, fingerprint: server.identity.fingerprint), token: "fixture-token")
        let reply = try await BridgeClient().dictate(Recording(url: url, duration: 2, bytes: 256_000), credentials: credentials, progress: { _ in })
        XCTAssertEqual(reply.text, "Network test.")
        let request = server.received()
        XCTAssertTrue(request.starts(with: Data("POST /v1/dictate HTTP/1.1".utf8)))
        let boundary = try XCTUnwrap(request.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertEqual(request.count - boundary.upperBound, 256_000)
    }

    func testRedirectAndResponseLimitAreEnforcedByRealSession() async throws {
        let target = try HTTPFixture(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        defer { target.stop() }
        let responses: [(Data, ClientFailure)] = [
            (Data("HTTP/1.1 302 Found\r\nLocation: \(target.address)/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), .redirected),
            (Data("HTTP/1.1 200 OK\r\nContent-Length: \(BridgeClient.maxResponseBytes + 1)\r\nConnection: close\r\n\r\n".utf8) + Data(repeating: 32, count: BridgeClient.maxResponseBytes + 1), .responseTooLarge),
            (Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8) + Data(repeating: 32, count: BridgeClient.maxResponseBytes + 1), .responseTooLarge)
        ]
        for (response, expected) in responses {
            let server = try HTTPFixture(response: response)
            defer { server.stop() }
            let credentials = BridgeCredentials(configuration: BridgeConfiguration(address: server.address, fingerprint: server.identity.fingerprint), token: "fixture-token")
            do { _ = try await BridgeClient().health(credentials); XCTFail("Erwarteter Transportfehler") }
            catch { XCTAssertEqual(error as? ClientFailure, expected) }
        }
        XCTAssertTrue(target.received().isEmpty, "Redirect darf weder Token noch Anfrage weiterreichen")
    }

    func testCancellationClosesInFlightConnection() async throws {
        let server = try HTTPFixture(response: nil)
        defer { server.stop() }
        var request = URLRequest(url: URL(string: server.address)!)
        request.timeoutInterval = 3
        let task = Task { try await LocalHTTPTransport().perform(request, file: nil, fingerprint: server.identity.fingerprint, progress: { _ in }) }
        let deadline = Date().addingTimeInterval(3)
        while server.received().isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(server.received().isEmpty)
        task.cancel()
        do { _ = try await task.value; XCTFail("Storno fehlt") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testWrongFingerprintSendsNoHTTPBytes() async throws {
        let server = try HTTPFixture(response: nil)
        defer { server.stop() }
        let credentials = BridgeCredentials(configuration: BridgeConfiguration(address: server.address, fingerprint: String(repeating: "0", count: 64)), token: "fixture-token")
        do { _ = try await BridgeClient().health(credentials); XCTFail("Falscher Pin wurde akzeptiert") }
        catch { XCTAssertEqual(error as? ClientFailure, .identityChanged) }
        XCTAssertTrue(server.received().isEmpty, "Token und Audio dürfen erst nach Pin-Prüfung gesendet werden")
    }

    func testPinnedCertificateStillChecksExpiry() throws {
        let identity = try TestTLSIdentity()
        var trust: SecTrust?
        SecTrustCreateWithCertificates(identity.certificate, SecPolicyCreateSSL(true, nil), &trust)
        let checked = try XCTUnwrap(trust)
        try PinnedTrust.validate(checked, fingerprint: identity.fingerprint)
        SecTrustSetVerifyDate(checked, Date().addingTimeInterval(366 * 86400) as CFDate)
        XCTAssertThrowsError(try PinnedTrust.validate(checked, fingerprint: identity.fingerprint)) {
            XCTAssertEqual($0 as? ClientFailure, .invalidCertificate)
        }
    }

    #if !DEBUG
    func testReleaseBlocksHTTPDespiteDevelopmentConsent() {
        for consent in [false, true] {
            XCTAssertThrowsError(try BridgeConfiguration(address: "http://mac.local:8188", allowInsecureDevelopment: consent).endpoint()) {
                XCTAssertEqual($0 as? ClientFailure, .insecureDisabled)
            }
        }
    }
    #endif
}

private final class HTTPFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StillePostMobile.HTTPFixture")
    private let listener: NWListener
    private let response: Data?
    private let lock = NSLock()
    private var bytes = Data()
    private var connections: [NWConnection] = []
    let identity: TestTLSIdentity
    var address: String { "https://127.0.0.1:\(listener.port!.rawValue)" }

    init(response: Data?) throws {
        self.response = response
        identity = try TestTLSIdentity()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connections.append(connection); connection.start(queue: queue); read(connection, buffer: Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, listener.port != nil else {
            listener.cancel(); throw ClientFailure.unavailable
        }
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            lock.lock(); bytes = buffer; lock.unlock()
            if let boundary = buffer.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) {
                let length = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if buffer.count - boundary.upperBound >= length {
                    if let response {
                        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                                        completion: .contentProcessed { _ in })
                    }
                    return
                }
            }
            if !complete && error == nil { read(connection, buffer: buffer) }
        }
    }

    func received() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func stop() { queue.sync { listener.cancel(); connections.forEach { $0.cancel() }; connections.removeAll() } }
}
