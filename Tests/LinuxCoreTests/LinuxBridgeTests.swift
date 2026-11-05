import Foundation
import Glibc
import LinuxNative
import XCTest

@testable import StillePostCore

final class LinuxBridgeTests: XCTestCase {
    private func identity() throws -> LinuxBridgeIdentity {
        var certificate: UnsafeMutablePointer<CChar>?
        var key: UnsafeMutablePointer<CChar>?
        guard sp_identity_create(&certificate, &key) == 1, let certificate, let key else {
            throw LinuxFailure.secret
        }
        defer {
            sp_free(certificate)
            sp_free(key)
        }
        return LinuxBridgeIdentity(
            certificate: String(cString: certificate), privateKey: String(cString: key))
    }
    func testTLSIdentityRejectsDifferentKeyAndKeepsFingerprint() throws {
        let first = try identity()
        let second = try identity()
        XCTAssertEqual(first.fingerprint?.count, 64)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        let context = try XCTUnwrap(first.context())
        sp_tls_context_free(context)
        XCTAssertNil(
            LinuxBridgeIdentity(certificate: first.certificate, privateKey: second.privateKey)
                .context())
        XCTAssertNil(
            LinuxBridgeIdentity(certificate: "invalid", privateKey: first.privateKey).context())
    }
    func testCertificateRenewalRetainsPrivateKeyAndChangesPin() throws {
        let first = try identity()
        var certificate: UnsafeMutablePointer<CChar>?
        let status = first.certificate.withCString { cert in
            first.privateKey.withCString { sp_identity_renew(cert, $0, &certificate) }
        }
        XCTAssertEqual(status, 1)
        let pointer = try XCTUnwrap(certificate)
        defer { sp_free(pointer) }
        let renewed = LinuxBridgeIdentity(
            certificate: String(cString: pointer), privateKey: first.privateKey)
        XCTAssertNotEqual(first.fingerprint, renewed.fingerprint)
        let context = try XCTUnwrap(renewed.context())
        sp_tls_context_free(context)
    }
    func testRouterAuthenticatesEveryRouteAndBoundsConcurrentWork() async throws {
        let handlers = BridgeHandlers(
            transcribe: { _ in
                try await Task.sleep(nanoseconds: 300_000_000)
                return "Künstlicher Test"
            },
            cleanup: { text in
                CleanupService.Result(
                    text: text, usedFallback: false, fallbackReason: nil, endpoint: nil)
            }, cleanupEnabled: true, version: "test")
        let router = BridgeRouter(
            handlers: handlers, maxBodyBytes: 1024, tokenProvider: { "fixture-token" })
        for route in ["/v1/health", "/v1/dictate", "/v1/cleanup", "/unknown"] {
            for token in [nil, "", "wrong", "fixture-token-extra"] as [String?] {
                let response = await router.respond(
                    to: BridgeRequest(
                        method: "POST", path: route, bearerToken: token, body: Data("audio".utf8)))
                XCTAssertEqual(response.status, 401)
            }
        }
        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await router.respond(
                        to: BridgeRequest(
                            method: "POST", path: "/v1/dictate", bearerToken: "fixture-token",
                            body: Data("audio".utf8))
                    ).status
                }
            }
            var result: [Int] = []
            for await status in group { result.append(status) }
            return result
        }
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 3)
        XCTAssertEqual(statuses.filter { $0 == 503 }.count, 2)
    }
    private func freePort() throws -> Int {
        let fd = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw LinuxFailure.protocolFailure }
        defer { _ = Glibc.close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                guard Glibc.bind(fd, pointer, size) == 0 else { return Int32(-1) }
                return getsockname(fd, pointer, &size)
            }
        }
        guard status == 0 else { throw LinuxFailure.protocolFailure }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private func exchange(port: Int, certificate: URL, request: String) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "s_client", "-connect", "127.0.0.1:\(port)", "-CAfile", certificate.path,
            "-verify_return_error", "-quiet",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { LinuxChildProcess.stop(process) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer {
            timeout.cancel()
            LinuxChildProcess.stop(process)
        }
        try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        let response = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: response, encoding: .utf8) ?? ""
    }
    func testActualTLSRequiresTokenAndRejectsLengthBeforeBody() throws {
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
        let value = try identity()
        let port = try freePort()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = directory.appendingPathComponent("certificate.pem")
        try Data(value.certificate.utf8).write(to: certificate)
        let service = LinuxBridgeService(
            identityProvider: { value }, tokenProvider: { "linux-test-token" },
            handlersProvider: { _ in
                BridgeHandlers(
                    transcribe: { _ in "Künstlicher Test" },
                    cleanup: { text in
                        CleanupService.Result(
                            text: text, usedFallback: false, fallbackReason: nil, endpoint: nil)
                    }, cleanupEnabled: true, version: "test")
            })
        defer { service.stop() }
        let ready = expectation(description: "TLS listener")
        service.onStatus = { active, _ in if active { ready.fulfill() } }
        var config = Config()
        config.bridge.enabled = true
        config.bridge.port = port
        config.bridge.maxRequestMegabytes = 1
        service.configure(config)
        wait(for: [ready], timeout: 3)
        let unauthorized = try exchange(
            port: port, certificate: certificate,
            request: "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(unauthorized.hasPrefix("HTTP/1.1 401"))
        let healthy = try exchange(
            port: port, certificate: certificate,
            request:
                "GET /v1/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer linux-test-token\r\nContent-Length: 0\r\n\r\n"
        )
        XCTAssertTrue(healthy.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(healthy.contains("\"ok\":true"))
        let oversized = try exchange(
            port: port, certificate: certificate,
            request:
                "POST /v1/dictate HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer linux-test-token\r\nContent-Length: 1048577\r\n\r\n"
        )
        XCTAssertTrue(oversized.hasPrefix("HTTP/1.1 413"))
    }
}
