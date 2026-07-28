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

    /// Liest das Token: zuerst Umgebungsvariable, dann Schlüsselbund.
    /// `nil` bedeutet „noch keins angelegt“ — die Brücke lehnt dann alles ab.
    public static func load() -> String? {
        if let fromEnv = ProcessInfo.processInfo.environment[environmentVariable],
           !fromEnv.isEmpty {
            return fromEnv
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
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

    public static func store(_ token: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
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
                return L10n.format("core.bridge.keychain_error", status)
            }
        }
    }
}
