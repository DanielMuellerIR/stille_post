import Foundation

/// Der QR-Inhalt ist ein Zugangsschlüssel, kein Diagnoseobjekt. Er wird nur nach
/// ausdrücklicher Aktion direkt auf dem Mac angezeigt und niemals protokolliert.
public struct BridgePairing: Encodable {
    public let v = 1
    public let url: String
    public let pin: String
    public let token: String

    public init(port: Int, identity: BridgeIdentity, token: String) throws {
        guard (1...65535).contains(port), !token.isEmpty else { throw BridgeIdentity.IdentityError.invalid }
        self.url = BridgeAddress.baseURL(port: port)
        self.pin = identity.fingerprint
        self.token = token
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}
