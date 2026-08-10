import Foundation

/// Ein IPv6-Netzbereich: 16 Byte Adresse plus Länge des Präfixes in Bit.
///
/// Gebraucht wird das, um zu entscheiden, ob eine Gegenstelle im selben Netz
/// liegt wie dieser Mac. Der Vergleich läuft bewusst über die Bytes und nicht
/// über die Schreibweise: Dieselbe IPv6-Adresse lässt sich als
/// „2001:db8:0:0:0:0:0:1“ oder „2001:db8::1“ schreiben, und ein Textvergleich
/// würde die beiden für verschieden halten.
public struct IPv6Prefix: Equatable, Sendable {

    public let bytes: [UInt8]
    public let bits: Int

    public init(bytes: [UInt8], bits: Int) {
        self.bytes = bytes
        self.bits = bits
    }

    /// Textform („2a00:db8:1:2::/64“) — vor allem für Tests und Protokollzeilen.
    public init?(_ text: String, bits: Int) {
        guard let bytes = IPv6Prefix.parse(text), (0...128).contains(bits) else { return nil }
        self.init(bytes: bytes, bits: bits)
    }

    /// Liegt `candidate` (16 Byte) in diesem Netzbereich? Verglichen werden genau
    /// die ersten `bits` Bit, erst byteweise und dann das angebrochene Byte.
    public func contains(_ candidate: [UInt8]) -> Bool {
        guard candidate.count == 16, bytes.count == 16 else { return false }
        let fullBytes = bits / 8
        let restBits = bits % 8
        for index in 0..<fullBytes where candidate[index] != bytes[index] {
            return false
        }
        if restBits > 0 {
            // Maske für die verbleibenden Bits: bei 4 Rest-Bits also 1111_0000.
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - restBits))
            if candidate[fullBytes] & mask != bytes[fullBytes] & mask { return false }
        }
        return true
    }

    /// Wandelt eine IPv6-Textform in ihre 16 Bytes um. `nil`, wenn der Text keine
    /// gültige IPv6-Adresse ist.
    public static func parse(_ text: String) -> [UInt8]? {
        var storage = in6_addr()
        guard inet_pton(AF_INET6, text, &storage) == 1 else { return nil }
        return withUnsafeBytes(of: storage) { Array($0) }
    }
}

/// Die IPv6-Netze, in denen dieser Mac selbst steckt.
///
/// Warum das für die Brücke zählt: Im Heimnetz vergibt der Router (FRITZ!Box)
/// allen Geräten Adressen aus demselben globalen Präfix — dem iPhone genauso wie
/// diesem Mac. Solche Adressen sehen „öffentlich“ aus, gehören aber zum eigenen
/// Netz. Wer nur nach den klassischen privaten Bereichen sucht, sperrt deshalb
/// genau das iPhone aus, für das die Brücke gebaut ist.
public enum LocalNetworkInterfaces {

    /// Präfixe aller aktiven, nicht-Loopback-Schnittstellen mit IPv6-Adresse.
    ///
    /// Die Präfixlänge kommt aus der Netzmaske der Schnittstelle, wird also nicht
    /// auf /64 geraten. Ein Gerät aus dem Internet hat ein anderes Präfix und
    /// fällt weiterhin durch; zusätzlich schützt weiterhin das Token.
    public static func ipv6Prefixes() -> [IPv6Prefix] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var prefixes: [IPv6Prefix] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let rawAddress = entry.pointee.ifa_addr,
                  rawAddress.pointee.sa_family == UInt8(AF_INET6),
                  let rawMask = entry.pointee.ifa_netmask else { continue }

            let address = bytes(of: rawAddress)
            let mask = bytes(of: rawMask)
            guard address.count == 16, mask.count == 16 else { continue }
            let prefix = IPv6Prefix(bytes: address, bits: leadingOneBits(mask))
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        return prefixes
    }

    /// Die 16 Adressbytes aus einer `sockaddr`-Struktur der Schnittstellenliste.
    private static func bytes(of address: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
        address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
            withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
        }
    }

    /// Länge des Präfixes: die Anzahl führender Einsen der Netzmaske.
    /// Beim ersten Byte, das nicht mehr komplett aus Einsen besteht, ist Schluss —
    /// die führenden Einsen von `byte` sind die führenden Nullen von `~byte`
    /// (1111_1100 invertiert ist 0000_0011, also 6).
    static func leadingOneBits(_ mask: [UInt8]) -> Int {
        var bits = 0
        for byte in mask {
            if byte == 0xFF { bits += 8; continue }
            bits += (~byte).leadingZeroBitCount
            break
        }
        return bits
    }
}
