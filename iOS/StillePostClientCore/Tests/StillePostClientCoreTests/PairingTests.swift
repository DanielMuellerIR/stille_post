import XCTest
@testable import StillePostClientCore

final class PairingTests: XCTestCase {
    private var valid: [String: Any] { ["v": 1, "url": "https://mac.local:8188", "pin": String(repeating: "a", count: 64), "token": String(repeating: "b", count: 43)] }
    private func decode(_ value: [String: Any]) throws -> BridgeCredentials {
        try BridgePairing.decode(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
    func testPairingContainsOnlyRequiredDataAndNeedsExplicitTrustSource() throws {
        let credentials = try decode(valid)
        XCTAssertEqual(credentials.configuration.address, "https://mac.local:8188")
        XCTAssertEqual(credentials.configuration.fingerprint, String(repeating: "a", count: 64))
        XCTAssertFalse(credentials.configuration.allowInsecureDevelopment)
        XCTAssertEqual(try JSONDecoder().decode(BridgeCredentials.self, from: JSONEncoder().encode(credentials)).configuration, credentials.configuration)
    }
    func testMalformedUnversionedInsecureAndForeignPairingsAreRejected() throws {
        for (key, replacement) in [("v", 2 as Any), ("v", true), ("url", "http://mac.local:8188"), ("url", "https://example.org"), ("pin", ""), ("token", "bad\r\nheader"), ("token", "short")] {
            var changed = valid; changed[key] = replacement
            XCTAssertThrowsError(try decode(changed), key)
        }
        var extra = valid; extra["redirect"] = "https://example.org"
        XCTAssertThrowsError(try decode(extra))
        for key in valid.keys { var missing = valid; missing[key] = nil; XCTAssertThrowsError(try decode(missing)) }
        XCTAssertThrowsError(try BridgePairing.decode(String(repeating: "a", count: 4097)))
    }
    func testLegacyConfigurationLoadsButNeverEnablesHTTP() throws {
        let data = Data(#"{"address":"http://mac.local:8188","allowInsecureDevelopment":true}"#.utf8)
        let legacy = try JSONDecoder().decode(BridgeConfiguration.self, from: data)
        XCTAssertThrowsError(try legacy.endpoint())
        for consent in [false, true] {
            XCTAssertThrowsError(try BridgeConfiguration(address: "http://mac.local", allowInsecureDevelopment: consent, fingerprint: String(repeating: "a", count: 64)).endpoint())
        }
    }
}
