import Foundation
import Security
import CryptoKit
@testable import StillePostClientCore

final class TestTLSIdentity {
    let certificate: SecCertificate
    let identity: SecIdentity
    let label = "stillepost.client.test." + UUID().uuidString
    var fingerprint: String { SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined() }
    init() throws {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256, kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: label]] as CFDictionary, &error) else { throw ClientFailure.invalidCertificate }
        do {
            guard let certificate = SecCertificateCreateWithData(nil, try Self.certificateDER(key: key) as CFData) else { throw ClientFailure.invalidCertificate }
            guard SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary, nil) == errSecSuccess else { throw ClientFailure.storageFailed }
            var identity: SecIdentity?
            guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess, let identity else { throw ClientFailure.storageFailed }
            self.certificate = certificate; self.identity = identity
        } catch {
            SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label] as CFDictionary)
            throw error
        }
    }
    deinit {
        SecItemDelete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: label] as CFDictionary)
    }
    static func certificateDER(key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { throw ClientFailure.invalidCertificate }
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
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else { throw ClientFailure.invalidCertificate }
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
