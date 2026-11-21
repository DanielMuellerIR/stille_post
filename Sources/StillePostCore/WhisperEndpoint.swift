import Foundation

/// Geprüfter Endpunkt für den lokalen Whisper-Server.
///
/// Audio ist die strengste Datenschutzgrenze der App. Deshalb reicht ein
/// syntaktisch gültiger URL nicht: Der Host muss eine explizite Loopback-Adresse
/// sein. Namen wie `localhost` werden bewusst nicht per DNS aufgelöst, weil deren
/// Auflösung außerhalb unserer Kontrolle liegt.
public struct WhisperEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let inferenceURL: URL
    /// Normalisierter Loopback-Host (kleingeschrieben, ohne IPv6-Klammern),
    /// z. B. "127.0.0.1", "127.23.4.5" oder "::1" — genau die Adresse, an die
    /// ein Autostart den whisper-server binden muss.
    public let host: String
    public let port: Int

    public init(serverURL: String) throws {
        guard var components = URLComponents(string: serverURL),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              CleanupNetworkPolicy.loopbackHost(host),
              let port = components.port,
              (1...65_535).contains(port),
              (components.path.isEmpty || components.path == "/") else {
            throw ValidationError.notLoopback(serverURL)
        }

        components.path = ""
        guard let baseURL = components.url else {
            throw ValidationError.notLoopback(serverURL)
        }
        self.baseURL = baseURL
        self.inferenceURL = baseURL.appendingPathComponent("inference")
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        self.port = port
    }

    public enum ValidationError: Error, LocalizedError, Equatable {
        case notLoopback(String)

        public var errorDescription: String? {
            switch self {
            case .notLoopback(let value):
                return L10n.format("core.whisper.loopback_only", value)
            }
        }
    }
}
