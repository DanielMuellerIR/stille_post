import Foundation
import Security

/// Gemeinsame Schreiblogik für Generic-Password-Einträge (Brücken-Token,
/// Cleanup-API-Key): Vorhandene Einträge werden AKTUALISIERT, nur fehlende neu
/// angelegt. Das frühere Löschen-dann-Anlegen hatte eine gefährliche Lücke:
/// Schlug das Anlegen fehl, war der alte, gültige Wert bereits gelöscht — eine
/// misslungene Token-Regeneration sperrte so alle eingerichteten Geräte aus.
///
/// `update`/`add` sind nur für Tests einspeisbar; produktiv laufen die echten
/// Security-Funktionen.
enum KeychainUpsert {

    typealias UpdateFunction = (_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    typealias AddFunction = (_ attributes: CFDictionary) -> OSStatus

    /// Schreibt `value` unter `service`. Liefert den OSStatus der maßgeblichen
    /// Operation; `errSecSuccess` heißt gespeichert. Bei jedem anderen Status
    /// ist der bisherige Eintrag unangetastet.
    static func store(
        service: String, value: Data,
        update: UpdateFunction = { SecItemUpdate($0, $1) },
        add: AddFunction = { SecItemAdd($0, nil) }
    ) -> OSStatus {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attributes = [kSecValueData as String: value]
        let updateStatus = update(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = value
        return add(addQuery as CFDictionary)
    }
}
