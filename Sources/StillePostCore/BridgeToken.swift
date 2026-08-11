import Foundation

/// Zugangs-Token der Netzwerk-Brücke.
///
/// Das Token ist das einzige Geheimnis, mit dem ein Gerät im Heimnetz die Brücke
/// benutzen darf. Es liegt deshalb im macOS-Schlüsselbund und NIE in
/// `config.json`, in Logs oder in einem Kommandozeilenargument — genau wie der
/// Cleanup-API-Key.
public enum BridgeToken {

    /// Schlüsselbund-Kennung des Brücken-Tokens.
    public static let keychainService = "StillePost Bridge Token"

    /// Umgebungsvariable für Tests und skriptierte Läufe. Sie hat Vorrang, damit
    /// ein Testlauf nie den persönlichen Schlüsselbund anfassen muss.
    public static let environmentVariable = "STILLEPOST_BRIDGE_TOKEN"

    /// Ergebnis eines Leseversuchs.
    ///
    /// Die Unterscheidung ist wichtig: „noch keins angelegt“ ist der normale
    /// Anfangszustand, für den der Hinweis zum Anlegen genau richtig ist. Ein
    /// Schlüsselbund-Fehler dagegen (gesperrter Schlüsselbund, verweigerter
    /// Zugriff) ist eine Störung — dort existiert das Token möglicherweise sehr
    /// wohl, und derselbe Hinweis würde in die Irre führen.
    public enum LoadOutcome: Equatable {
        case token(String)
        case missing
        case failed(OSStatus)
    }

    /// Nur für Tests einspeisbar; produktiv läuft die echte Security-Funktion.
    typealias CopyMatchingFunction = (
        _ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus

    /// Liest das Token: zuerst Umgebungsvariable, dann Schlüsselbund.
    public static func loadOutcome() -> LoadOutcome {
        loadOutcome(
            environment: ProcessInfo.processInfo.environment,
            copyMatching: { SecItemCopyMatching($0, $1) }
        )
    }

    static func loadOutcome(
        environment: [String: String],
        copyMatching: CopyMatchingFunction
    ) -> LoadOutcome {
        if let fromEnv = environment[environmentVariable], !fromEnv.isEmpty {
            return .token(fromEnv)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            // Eintrag da, aber unbrauchbar (leer oder kein UTF-8). Das ist kein
            // „noch keins angelegt“, sondern ein kaputter Eintrag — deshalb als
            // Fehler melden statt zum Anlegen aufzufordern.
            return .failed(errSecDecode)
        }
        return .token(token)
    }

    /// Bequeme Kurzform für alle Stellen, die nur „gültiges Token oder nicht“
    /// wissen müssen (Token-Prüfung je Anfrage). Wer dem Nutzer einen Grund
    /// nennen will, nimmt `loadOutcome()`.
    public static func load() -> String? {
        if case .token(let token) = loadOutcome() { return token }
        return nil
    }

    /// Entscheidet den CLI-Befehl mit höchstens einem Lesezugriff. Ohne
    /// ``--new`` wird ein vorhandener Wert wiederverwendet, ein echter
    /// Lesefehler abgebrochen und nur bei ``missing`` neu erzeugt. Mit
    /// ``--new`` ist der ausdrückliche Ersetzungswunsch bereits eindeutig und
    /// der Schlüsselbund muss vorher nicht gelesen werden.
    public static func resolveForCommand(
        wantsNew: Bool,
        loadOutcome: () -> LoadOutcome = { BridgeToken.loadOutcome() },
        regenerate: () throws -> String = { try BridgeToken.regenerate() }
    ) throws -> (token: String, reused: Bool) {
        if wantsNew { return (try regenerate(), false) }
        switch loadOutcome() {
        case .token(let token):
            return (token, true)
        case .missing:
            return (try regenerate(), false)
        case .failed(let status):
            throw LoadError.keychain(status)
        }
    }

    /// Erzeugt ein neues Token und speichert es (überschreibt ein vorhandenes).
    /// Rückgabe ist das neue Token — der Aufrufer entscheidet, ob er es anzeigt
    /// oder direkt in die Zwischenablage legt.
    @discardableResult
    public static func regenerate() throws -> String {
        let token = generate()
        try store(token)
        return token
    }

    /// 32 Zufallsbytes, URL-sicher kodiert. Lang genug, dass Durchprobieren im
    /// Heimnetz aussichtslos ist, und kurz genug für einmaliges Einfügen.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // Kryptografisch sicherer Zufall; `arc4random_buf` ist auf macOS genau dafür da.
        arc4random_buf(&bytes, bytes.count)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Aktualisiert einen vorhandenen Eintrag, statt ihn vorher zu löschen —
    /// sonst wäre bei einem Speicherfehler der alte, gültige Token schon weg
    /// und alle eingerichteten Geräte ausgesperrt (Details: `KeychainUpsert`).
    public static func store(_ token: String) throws {
        let status = KeychainUpsert.store(service: keychainService, value: Data(token.utf8))
        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }
    }

    /// Löscht das Token. Danach ist die Brücke für alle Geräte gesperrt.
    public static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ] as CFDictionary)
    }

    /// Vergleich in konstanter Zeit. Ein früh abbrechender Vergleich verrät über
    /// die Antwortzeit, wie viele Zeichen schon stimmen — bei einem Geheimnis im
    /// Netz ist das eine echte, wenn auch mühsame Angriffsfläche.
    public static func matches(_ candidate: String, expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        guard !b.isEmpty else { return false }
        // Über die längere Länge laufen, damit auch die Länge nichts verrät.
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? Int(a[index]) : 0
            let right = index < b.count ? Int(b[index]) : 0
            difference |= left ^ right
        }
        return difference == 0
    }

    public enum StoreError: Error, LocalizedError {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return L10n.format("core.bridge.keychain_error", String(status))
            }
        }
    }

    /// Der Schlüsselbund war nicht lesbar. Bewusst eine eigene Fehlerart neben
    /// `StoreError`: „nicht lesbar“ und „nicht speicherbar“ haben verschiedene
    /// Ursachen und brauchen verschiedene Hinweise.
    public enum LoadError: Error, LocalizedError {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return L10n.format("core.bridge.keychain_read_error", String(status))
            }
        }
    }
}
