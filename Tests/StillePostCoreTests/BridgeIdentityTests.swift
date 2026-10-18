import XCTest
import Security
import Network
@testable import StillePostCore

final class BridgeIdentityTests: XCTestCase {
    func testRenewalChangesPinPreservesKeyAndPersists() throws {
        let namespace = "stillepost.test.renew." + UUID().uuidString
        defer { XCTAssertNoThrow(try BridgeIdentity.delete(namespace: namespace)) }
        let first = try BridgeIdentity.loadOrCreate(namespace: namespace)
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(first.identity, &key), errSecSuccess)
        let attributes = SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any]
        XCTAssertEqual(attributes?[kSecAttrIsExtractable as String] as? Bool, false)
        let renewed = try BridgeIdentity.renew(namespace: namespace)
        XCTAssertNotEqual(first.fingerprint, renewed.fingerprint)
        XCTAssertEqual(SecKeyCopyExternalRepresentation(try XCTUnwrap(SecCertificateCopyKey(first.certificate)), nil) as Data?,
                       SecKeyCopyExternalRepresentation(try XCTUnwrap(SecCertificateCopyKey(renewed.certificate)), nil) as Data?)
        XCTAssertEqual(try BridgeIdentity.loadOrCreate(namespace: namespace).fingerprint, renewed.fingerprint)
    }

    func testKeychainIdentityPersistsAndAuthenticatesTLS() throws {
        let namespace = "stillepost.test." + UUID().uuidString
        defer { XCTAssertNoThrow(try BridgeIdentity.delete(namespace: namespace)) }
        let first = try BridgeIdentity.loadOrCreate(namespace: namespace)
        let second = try BridgeIdentity.loadOrCreate(namespace: namespace)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint.count, 64)
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(first.certificate, SecPolicyCreateSSL(true, nil), &trust), errSecSuccess)
        let checked = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(checked, [first.certificate] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(checked, true), errSecSuccess)
        var trustError: CFError?
        XCTAssertTrue(SecTrustEvaluateWithError(checked, &trustError), String(describing: trustError))
        XCTAssertEqual(SecTrustSetVerifyDate(checked, Date().addingTimeInterval(3651 * 86400) as CFDate), errSecSuccess)
        XCTAssertFalse(SecTrustEvaluateWithError(checked, nil), "Abgelaufene Identität muss scheitern")
        let options = NWProtocolTLS.Options()
        let identity = try XCTUnwrap(sec_identity_create(first.identity))
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        let listener = try NWListener(using: NWParameters(tls: options), on: NWEndpoint.Port(rawValue: UInt16.random(in: 30000...50000))!)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "TLS listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
            if case .failed(let error) = state { XCTFail("TLS listener: \(error)"); ready.fulfill() }
        }
        listener.start(queue: DispatchQueue(label: "tls-proof"))
        wait(for: [ready], timeout: 5)
        listener.cancel()
    }
}
