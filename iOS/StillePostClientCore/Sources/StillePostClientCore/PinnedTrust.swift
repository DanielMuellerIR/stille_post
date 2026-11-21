import Foundation
import Security
import CryptoKit

public enum PinnedTrust {
    public static func validate(_ trust: SecTrust, fingerprint: String) throws {
        guard BridgeConfiguration.validFingerprint(fingerprint) else { throw ClientFailure.pairingRequired }
        // Das Kopieren der Kette kann schon eine Trust-Auswertung auslösen.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, nil)) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { throw ClientFailure.invalidCertificate }
        let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else { throw ClientFailure.identityChanged }
        // Die Identität kommt vom physischen QR-Code. Die SSL-Prüfung bewertet
        // Serverzweck, Signatur und Gültigkeit mit genau diesem Blatt als Anker.
        guard SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { throw ClientFailure.invalidCertificate }
    }
}
