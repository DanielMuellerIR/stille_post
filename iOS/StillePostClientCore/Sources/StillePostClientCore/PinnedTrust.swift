import Foundation
import Security
import CryptoKit

public enum PinnedTrust {
    public static func validate(_ trust: SecTrust, fingerprint: String) throws {
        guard BridgeConfiguration.validFingerprint(fingerprint),
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else { throw ClientFailure.pairingRequired }
        let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else { throw ClientFailure.identityChanged }
        // Die Identität kommt vom physischen QR-Code, nicht aus DNS oder einer CA.
        // Deshalb prüft SSL hier Serverzweck, Signatur und Gültigkeit ohne DNS-Namen.
        // Nur genau dieses Blatt darf Anker sein; AIA/Netz-Nachladen bleibt aus.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { throw ClientFailure.invalidCertificate }
    }
}
