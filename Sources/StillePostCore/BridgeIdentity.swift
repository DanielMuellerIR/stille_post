import Foundation
import Security
import CryptoKit

/// Dauerhafte, selbstsignierte TLS-Identität. Der private Schlüssel verlässt den
/// Schlüsselbund nie. Vertrauen entsteht ausschließlich durch Kopplung am Mac.
public struct BridgeIdentity {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    public var fingerprint: String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    }
    public static var namespace: String {
        let production = "io.github.danielmuellerir.stillepost.bridge.tls.v1"
        // Isolierte Bundle-/Geräteprüfungen dürfen die Alltagsidentität nicht ändern.
        if let value = ProcessInfo.processInfo.environment["STILLEPOST_BRIDGE_IDENTITY_NAMESPACE"],
           value.hasPrefix(production + ".test."), value.utf8.count < 200,
           value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }) { return value }
        return production
    }
    private static let lock = NSLock()

    public static func loadOrCreate(namespace: String = namespace) throws -> BridgeIdentity {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw IdentityError.invalid }
            return try resolve(certificate)
        }
        guard status == errSecItemNotFound else { throw IdentityError.keychain(status) }
        // Ein verwaister Schlüssel ist kein Anlass, ihn still zu ersetzen.
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: namespace, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
        var existingKey: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery.merging([kSecReturnRef as String: true]) { _, new in new } as CFDictionary, &existingKey)
        guard keyStatus == errSecItemNotFound else { throw IdentityError.keychain(keyStatus == errSecSuccess ? errSecDuplicateItem : keyStatus) }
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrIsExtractable as String: false, kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(namespace.utf8),
                kSecAttrLabel as String: namespace,
                kSecAttrIsExtractable as String: false,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: false]]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw IdentityError.keychain(errSecInternalError)
        }
        var createdCertificate: SecCertificate?
        do {
            let der = try certificateDER(key: key)
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw IdentityError.invalid }
            let add: [String: Any] = [kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: namespace, kSecValueRef as String: certificate]
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw IdentityError.keychain(status) }
            createdCertificate = certificate
            let identity = try resolve(certificate)
            let stored = KeychainUpsert.store(service: namespace, value: der)
            guard stored == errSecSuccess else {
                deleteCertificate(certificate)
                throw IdentityError.keychain(stored)
            }
            return identity
        } catch {
            if let createdCertificate {
                deleteCertificate(createdCertificate)
            }
            SecItemDelete(keyQuery as CFDictionary)
            throw error
        }
    }

    public static func renew(namespace: String = namespace) throws -> BridgeIdentity {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let oldCertificate = SecCertificateCreateWithData(nil, data as CFData) else { throw IdentityError.keychain(status) }
        let old = try resolve(oldCertificate)
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(old.identity, &privateKey) == errSecSuccess, let privateKey else { throw IdentityError.invalid }
        let der = try certificateDER(key: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { throw IdentityError.invalid }
        let added = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary, nil)
        guard added == errSecSuccess else { throw IdentityError.keychain(added) }
        var committed = false
        defer {
            if !committed { deleteCertificate(certificate) }
        }
        let identity = try resolve(certificate)
        let stored = KeychainUpsert.store(service: namespace, value: der)
        guard stored == errSecSuccess else {
            deleteCertificate(certificate)
            throw IdentityError.keychain(stored)
        }
        committed = true
        deleteCertificate(oldCertificate)
        return identity
    }

    private static func resolve(_ certificate: SecCertificate) throws -> BridgeIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw IdentityError.keychain(status) }
        return BridgeIdentity(identity: identity, certificate: certificate)
    }

    /// Nur ausdrückliches Zurücksetzen darf eine bestehende Identität ändern.
    /// Der Aufrufer muss zuvor den Listener stoppen und anschließend neu koppeln.
    public static func delete(namespace: String = namespace) throws {
        lock.lock(); defer { lock.unlock() }
        let metadata: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace]
        var item: CFTypeRef?
        let found = SecItemCopyMatching(metadata.merging([kSecReturnData as String: true]) { _, new in new } as CFDictionary, &item)
        guard found == errSecSuccess || found == errSecItemNotFound else { throw IdentityError.keychain(found) }
        if let data = item as? Data, let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            let status = deleteCertificate(certificate)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
        }
        for query in [metadata, [kSecClass as String: kSecClassKey, kSecAttrLabel as String: namespace,
                                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]] {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw IdentityError.keychain(status) }
        }
    }

    // Ein aus DER rekonstruiertes SecCertificate ist keine Schlüsselbund-ItemRef.
    // Issuer und Seriennummer identifizieren stattdessen genau den gespeicherten Eintrag.
    @discardableResult private static func deleteCertificate(_ certificate: SecCertificate) -> OSStatus {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate),
              let serial = SecCertificateCopySerialNumberData(certificate, nil) else { return errSecDecode }
        return SecItemDelete([kSecClass as String: kSecClassCertificate,
            kSecAttrIssuer as String: issuer, kSecAttrSerialNumber as String: serial] as CFDictionary)
    }

    public enum IdentityError: Error, LocalizedError {
        case keychain(OSStatus), invalid
        public var errorDescription: String? { L10n.text("core.bridge.identity_failed") }
    }

    // X.509 v3 mit ECDSA/SHA-256, Server-EKU und CA=false. Die wenigen DER-Typen
    // vermeiden externe Programme und temporäre Dateien mit privatem Schlüssel.
    private static func certificateDER(key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { throw IdentityError.invalid }
        let algorithm = DER.sequence(DER.oid([1,2,840,10045,4,3,2]))
        let name = DER.sequence(DER.wrap(0x31, DER.sequence(DER.oid([2,5,4,3]) + DER.wrap(0x0c, Data("Stille Post Bridge".utf8)))))
        let date = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        func time(_ date: Date) -> Data { DER.wrap(0x18, Data(formatter.string(from: date).utf8)) }
        var serial = [UInt8](repeating: 0, count: 16); arc4random_buf(&serial, serial.count); serial[0] &= 0x7f; serial[0] |= 1
        func ext(_ oid: [UInt64], _ value: Data, critical: Bool = false) -> Data {
            DER.sequence(DER.oid(oid) + (critical ? DER.wrap(0x01, Data([0xff])) : Data()) + DER.wrap(0x04, value))
        }
        let extensions = DER.wrap(0xa3, DER.sequence(
            ext([2,5,29,19], DER.sequence(Data()), critical: true)
            + ext([2,5,29,15], DER.wrap(0x03, Data([7,0x80])), critical: true)
            + ext([2,5,29,37], DER.sequence(DER.oid([1,3,6,1,5,5,7,3,1])))))
        let spki = DER.sequence(DER.sequence(DER.oid([1,2,840,10045,2,1]) + DER.oid([1,2,840,10045,3,1,7])) + DER.wrap(0x03, Data([0]) + publicBytes))
        let tbs = DER.sequence(DER.wrap(0xa0, DER.wrap(0x02, Data([2]))) + DER.wrap(0x02, Data(serial)) + algorithm + name
            + DER.sequence(time(date.addingTimeInterval(-300)) + time(date.addingTimeInterval(365 * 86400))) + name + spki + extensions)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else { throw IdentityError.invalid }
        return DER.sequence(tbs + algorithm + DER.wrap(0x03, Data([0]) + signature))
    }
}

private enum DER {
    static func wrap(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count; var bytes = [UInt8]()
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        return Data([tag]) + (data.count < 128 ? Data([UInt8(data.count)]) : Data([0x80 | UInt8(bytes.count)]) + Data(bytes)) + data
    }
    static func sequence(_ data: Data) -> Data { wrap(0x30, data) }
    static func oid(_ values: [UInt64]) -> Data {
        var bytes = [UInt8(values[0] * 40 + values[1])]
        for value in values.dropFirst(2) {
            var value = value; var part = [UInt8(value & 127)]; value >>= 7
            while value > 0 { part.insert(UInt8(value & 127) | 0x80, at: 0); value >>= 7 }
            bytes += part
        }
        return wrap(0x06, Data(bytes))
    }
}
