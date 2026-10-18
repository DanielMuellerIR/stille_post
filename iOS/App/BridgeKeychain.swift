import Foundation
import Security
import StillePostClientCore

actor BridgeKeychain {
    private let service = "io.github.danielmuellerir.stillepost.ios.bridge"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "bridge-token", kSecAttrSynchronizable as String: false]
    }

    func load() throws -> BridgeCredentials? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ClientFailure.storageFailed }
        guard let credentials = try? JSONDecoder().decode(BridgeCredentials.self, from: data),
              (try? credentials.configuration.endpoint()) != nil else { throw ClientFailure.pairingRequired }
        return credentials
    }

    // Adresse, Pin und Token bilden eine unteilbare Kopplung. Ein Speicherfehler
    // darf nie einen neuen Token mit der Identität der alten Verbindung mischen.
    func save(_ credentials: BridgeCredentials) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ClientFailure.storageFailed }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientFailure.storageFailed }
    }
}
