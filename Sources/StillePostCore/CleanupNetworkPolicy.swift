import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Keine Namensauflösung: Eine lokale Richtlinie vertraut nur numerischen
/// Loopback-Zielen. Dieselbe Grenze gilt vor Requests und vor Weiterleitungen.
enum CleanupNetworkPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.user == nil, c.password == nil, let host = c.host else { return false }
        return loopbackHost(host)
    }

    static func loopbackHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return UInt32(bigEndian: ipv4.s_addr) >> 24 == 127
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, host, &ipv6) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
    }

    struct Denied: Error, LocalizedError {
        var errorDescription: String? { L10n.text("core.cleanup.local_unavailable") }
    }
}
