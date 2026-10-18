import Foundation
import CoreFoundation

public enum BridgePairing {
    /// Nur die physisch am eigenen Mac gezeigte QR-Anzeige ist eine vertrauenswürdige
    /// Quelle. Diese Funktion lädt weder Zertifikat noch Fingerabdruck aus dem Netz.
    public static func decode(_ text: String) throws -> BridgeCredentials {
        guard text.utf8.count <= 4096, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["v", "url", "pin", "token"],
              let version = object["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let address = object["url"] as? String,
              let pin = object["pin"] as? String,
              let token = object["token"] as? String, token.utf8.count == 43,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ClientFailure.invalidPairing
        }
        let configuration = BridgeConfiguration(address: address, fingerprint: pin)
        do { _ = try configuration.endpoint() } catch { throw ClientFailure.invalidPairing }
        return BridgeCredentials(configuration: configuration, token: token)
    }
}
