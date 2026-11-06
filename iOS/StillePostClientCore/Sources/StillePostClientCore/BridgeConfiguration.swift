import Foundation
import Darwin

public enum ClientFailure: String, Error, Equatable, Sendable {
    case pairingRequired, invalidPairing, identityChanged, invalidCertificate, cameraUnavailable
    case invalidAddress, insecureDisabled, missingToken, microphoneDenied, recordingFailed
    case recordingExists, noAudio, recordingTooLarge, unavailable, unauthorized, busy
    case serverFailed, invalidResponse, responseTooLarge, redirected, storageFailed, interrupted, noSpeech, tooHot, memoryPressure, textTooLarge

    public var messageKey: String { "error.\(rawValue)" }
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var address: String
    public var allowInsecureDevelopment: Bool
    public var fingerprint: String?

    public init(address: String = "", allowInsecureDevelopment: Bool = false, fingerprint: String? = nil) {
        self.address = address
        self.allowInsecureDevelopment = allowInsecureDevelopment
        self.fingerprint = fingerprint
    }

    public func endpoint() throws -> URL {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure.invalidAddress }
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ClientFailure.invalidAddress }
        guard parts.scheme?.lowercased() == "https" else { throw ClientFailure.insecureDisabled }
        guard let host = parts.host,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", (1...65535).contains(parts.port ?? 443),
              Self.isLocalHost(host), let url = parts.url else { throw ClientFailure.invalidAddress }
        guard let fingerprint, Self.validFingerprint(fingerprint) else { throw ClientFailure.pairingRequired }
        return url
    }

    public static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.hasSuffix(".local") || name.hasSuffix(".local.") {
            let labels = name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".", omittingEmptySubsequences: false)
            return labels.count >= 2 && labels.allSatisfy { label in
                !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            }
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, name, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
            || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
    }
}

public struct BridgeCredentials: Codable, Sendable {
    public let configuration: BridgeConfiguration
    public let token: String

    public init(configuration: BridgeConfiguration, token: String) {
        self.configuration = configuration
        self.token = token
    }
}

public struct BridgeHealth: Codable, Equatable, Sendable {
    public let ok: Bool
    public let version: String
    public let cleanup: Bool
}

public struct DictationReply: Codable, Equatable, Sendable {
    public let text: String
    public let origin: String?
    public let sttSec: Double?
    public let cleanupSec: Double?
    public let usedFallback: Bool?

    public init(text: String, origin: String? = nil, sttSec: Double? = nil,
                cleanupSec: Double? = nil, usedFallback: Bool? = nil) {
        self.text = text; self.origin = origin; self.sttSec = sttSec
        self.cleanupSec = cleanupSec; self.usedFallback = usedFallback
    }
}
