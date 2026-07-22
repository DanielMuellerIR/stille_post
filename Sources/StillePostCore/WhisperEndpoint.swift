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
    public let port: Int

    public init(serverURL: String) throws {
        guard var components = URLComponents(string: serverURL),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              Self.isExplicitLoopback(host),
              let port = components.port,
              (components.path.isEmpty || components.path == "/") else {
            throw ValidationError.notLoopback(serverURL)
        }

        components.path = ""
        guard let baseURL = components.url else {
            throw ValidationError.notLoopback(serverURL)
        }
        self.baseURL = baseURL
        self.inferenceURL = baseURL.appendingPathComponent("inference")
        self.port = port
    }

    private static func isExplicitLoopback(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if normalized == "::1" { return true }

        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]), first == 127,
              octets.allSatisfy({ part in
                  guard !part.isEmpty, part.allSatisfy(\.isNumber),
                        let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else { return false }
        return true
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
