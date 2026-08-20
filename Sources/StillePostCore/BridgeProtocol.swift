import Foundation

/// Anfrage- und Antwortformat der Netzwerk-Brücke plus die Zerlegung des
/// HTTP-Textes. Bewusst ohne Netzwerkcode: So lässt sich das gesamte Verhalten
/// (Token-Prüfung, Größenlimit, Routen, Fehlerfälle) ohne offenen Port testen.
///
/// Es ist absichtlich nur ein winziger Teil von HTTP umgesetzt: eine Anfrage pro
/// Verbindung, `Content-Length` statt Chunked-Kodierung, kein Keep-alive. Mehr
/// braucht kein Kurzbefehl und kein `curl` — und weniger Code heißt hier auch
/// weniger Angriffsfläche.
public struct BridgeRequest: Equatable, Sendable {
    public var method: String
    /// Pfad ohne Abfrageteil, z. B. `/v1/dictate`.
    public var path: String
    /// Abfrageparameter, z. B. `["raw": "1"]`.
    public var query: [String: String]
    /// Inhalt des `Authorization: Bearer …`-Kopfes, falls vorhanden.
    public var bearerToken: String?
    public var body: Data

    // Einen `contentType` gibt es hier bewusst nicht: Audio erkennt der Decoder
    // am Inhalt, und die Bereinigungs-Route versucht direkt UTF-8. Das Feld war
    // geparst, aber von keiner Route gelesen — ein Medientyp-Versprechen, das
    // nirgends eingelöst wurde.
    public init(method: String, path: String, query: [String: String] = [:],
                bearerToken: String? = nil, body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.bearerToken = bearerToken
        self.body = body
    }
}

public struct BridgeResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    /// Baut eine JSON-Antwort aus einem bereits fertigen JSON-Objekt.
    public static func json(status: Int, object: [String: Any]) -> BridgeResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .fragmentsAllowed]))
            ?? Data("{}".utf8)
        return BridgeResponse(status: status, body: data)
    }

    /// Fehlerantwort. Der Text ist für Menschen gedacht und enthält nie ein
    /// Geheimnis — er geht über das Netz an ein Gerät, dem wir nur begrenzt trauen.
    public static func error(status: Int, message: String) -> BridgeResponse {
        json(status: status, object: ["error": message])
    }

    /// Vollständige HTTP-Antwort als Bytes. `Connection: close` ist Absicht: eine
    /// Anfrage pro Verbindung hält die Zustandsverwaltung trivial.
    public func httpData() -> Data {
        var header = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

/// Zerlegt rohe Bytes einer Verbindung in eine Anfrage.
public enum BridgeHTTP {

    /// Obergrenze für den Kopfbereich. Ein Gegenüber, das endlos Kopfzeilen
    /// schickt, soll nicht unbegrenzt Speicher belegen können.
    public static let maxHeaderBytes = 8 * 1024

    /// Die vier Bytes `\r\n\r\n` zwischen Kopf und Body. Wer Puffergrenzen aus
    /// Kopf- und Body-Limit zusammensetzt, muss sie mitzählen.
    public static let headerSeparatorBytes = 4

    public enum ParseResult: Equatable {
        /// Noch nicht alles da — weiterlesen.
        case incomplete
        case complete(BridgeRequest)
        /// Endgültig kaputt: mit dieser Antwort schließen.
        case failure(BridgeResponse)
    }

    /// Ergebnis der Kopf-Vorschau, bevor der Body vollständig ist.
    public enum HeaderProbe: Equatable {
        /// Kopf noch nicht vollständig — weiterlesen.
        case incomplete
        /// Kopf vollständig: Methode, Pfad und (falls gesendet) Bearer-Token.
        case complete(method: String, path: String, bearerToken: String?)
    }

    /// Schaut nur auf den Kopfbereich: Sobald der Trenner `\r\n\r\n` da ist,
    /// lassen sich Route und Token prüfen, ohne auf den (möglicherweise großen)
    /// Body zu warten — die Grundlage der frühen Token-Prüfung im Server.
    /// Kaputte Köpfe bewertet weiterhin `parse`; hier reicht `incomplete`.
    public static func probeHeader(_ buffer: Data) -> HeaderProbe {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator),
              let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound],
                                      encoding: .utf8) else {
            return .incomplete
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              isValidRequestLine(requestLine) else { return .incomplete }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .incomplete }
        let (path, _) = splitTarget(String(parts[1]))
        return .complete(method: String(parts[0]).uppercased(), path: path,
                         bearerToken: bearerToken(in: headerFields(lines)))
    }

    /// Prüft, ob die gesammelten Bytes eine vollständige Anfrage enthalten.
    /// `maxBodyBytes` begrenzt den Inhalt; ein zu großes `Content-Length` wird
    /// abgelehnt, bevor überhaupt Daten gelesen werden.
    public static func parse(_ buffer: Data, maxBodyBytes: Int) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            // Solange der Trenner fehlt, dürfen die letzten bis zu drei Bytes
            // sein angefangenes Präfix sein (TCP zerteilt beliebig). Ohne diesen
            // Zuschlag scheiterte ein Kopf von exakt `maxHeaderBytes` allein
            // daran, dass `\r\n\r\n` in zwei Paketen ankam. Sobald der Trenner
            // da ist, misst die Prüfung weiter unten den Kopf selbst — die
            // eigentliche Grenze bleibt also unverändert.
            if buffer.count > maxHeaderBytes + headerSeparatorBytes - 1 {
                return .failure(.error(status: 400, message: L10n.text("core.bridge.bad_request")))
            }
            return .incomplete
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard headerData.count <= maxHeaderBytes,
              let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(.error(status: 400, message: L10n.text("core.bridge.bad_request")))
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              isValidRequestLine(requestLine) else {
            return .failure(.error(status: 400, message: L10n.text("core.bridge.bad_request")))
        }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .failure(.error(status: 400, message: L10n.text("core.bridge.bad_request")))
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        let headers = headerFields(lines)

        // Chunked-Kodierung ist nicht umgesetzt; ehrlich ablehnen statt still
        // falsch zu lesen. Kurzbefehle und curl schicken ohnehin Content-Length.
        if let encoding = headers["transfer-encoding"], !encoding.isEmpty {
            return .failure(.error(status: 501, message: L10n.text("core.bridge.no_chunked")))
        }

        let declaredLength = Int(headers["content-length"] ?? "0") ?? -1
        guard declaredLength >= 0 else {
            return .failure(.error(status: 400, message: L10n.text("core.bridge.bad_request")))
        }
        guard declaredLength <= maxBodyBytes else {
            return .failure(.error(status: 413, message: L10n.format(
                "core.bridge.too_large", ByteSize.megabytes(Int64(maxBodyBytes))
            )))
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= declaredLength else { return .incomplete }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: declaredLength)])

        let (path, query) = splitTarget(target)
        return .complete(BridgeRequest(
            method: method, path: path, query: query,
            bearerToken: bearerToken(in: headers), body: body
        ))
    }

    /// Die unterstützte HTTP-Request-Line ist reines sichtbares ASCII plus
    /// Leerzeichen. Pfade mit anderen Zeichen kommen HTTP-konform prozentkodiert;
    /// rohe Unicode-Zeilen-/Absatztrenner dürfen dagegen nie bis ins lokale
    /// Diagnoseprotokoll gelangen.
    private static func isValidRequestLine(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value <= 0x7E
        }
    }

    /// Kopfzeilen "Name: Wert" in ein Wörterbuch (Namen kleingeschrieben).
    private static func headerFields(_ lines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    /// Bearer-Token aus dem Authorization-Kopf, falls vorhanden.
    private static func bearerToken(in headers: [String: String]) -> String? {
        guard let authorization = headers["authorization"] else { return nil }
        let prefix = "bearer "
        guard authorization.lowercased().hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Trennt `/v1/dictate?raw=1` in Pfad und Parameter.
    static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<mark])
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let fields = pair.split(separator: "=", maxSplits: 1)
            guard let name = fields.first, !name.isEmpty else { continue }
            let value = fields.count > 1 ? String(fields[1]) : ""
            query[String(name).lowercased()] = value.removingPercentEncoding ?? value
        }
        return (path, query)
    }
}

/// Adressprüfung: Die Brücke nimmt nur Verbindungen aus dem eigenen Netz an.
/// Ein Gegenüber aus dem öffentlichen Internet — etwa durch eine versehentliche
/// Portweiterleitung im Router — wird abgewiesen, noch bevor das Token zählt.
public enum BridgePeer {

    public static func isLocalNetwork(_ address: String) -> Bool {
        isLocalNetwork(address, ownPrefixes: LocalNetworkInterfaces.ipv6Prefixes)
    }

    /// `ownPrefixes` ist eine Funktion und keine fertige Liste, damit die
    /// Schnittstellen des Macs nur dann abgefragt werden, wenn es wirklich darauf
    /// ankommt — und damit Tests eigene Netze vorgeben können.
    static func isLocalNetwork(_ address: String, ownPrefixes: () -> [IPv6Prefix]) -> Bool {
        // Zonen-Zusatz von Link-Local-Adressen abschneiden ("fe80::1%en0").
        var host = address.lowercased()
        if let percent = host.firstIndex(of: "%") { host = String(host[host.startIndex..<percent]) }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // Ohne Doppelpunkt kann es nur eine IPv4-Adresse (oder ein Name) sein.
        if !host.contains(":") { return isPrivateIPv4(host) }

        // Ab hier wird über die 16 Bytes entschieden und nicht über den Text.
        // Wichtig, weil eine IPv6-Adresse ihre letzten vier Bytes in
        // Punkt-Schreibweise tragen darf: "2a00:1234::192.168.1.1" ist eine
        // GLOBALE Adresse aus dem Internet und sieht im Text trotzdem nach einem
        // privaten IPv4-Netz aus.
        guard let bytes = IPv6Prefix.parse(host) else { return false }
        if isPrivateIPv6(bytes) { return true }
        // Echte IPv4-in-IPv6-Form: So meldet macOS eine IPv4-Gegenstelle auf
        // einem Dual-Stack-Port. Nur diese eine Einbettung zählt.
        if let ipv4 = mappedIPv4(bytes) { return isPrivateIPv4(ipv4) }

        // Bleibt eine öffentlich aussehende IPv6-Adresse. Sie zählt genau dann zum
        // Heimnetz, wenn sie im selben Netzbereich liegt wie eine Adresse dieses
        // Macs: Die FRITZ!Box gibt allen Geräten im Haus Adressen aus demselben
        // globalen Präfix, dem iPhone genauso wie diesem Mac. Ein Gegenüber aus
        // dem Internet hat ein anderes Präfix und fällt weiterhin durch.
        return ownPrefixes().contains { $0.contains(bytes) }
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var values: [Int] = []
        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy(\.isNumber),
                  let value = Int(octet), (0...255).contains(value) else { return false }
            values.append(value)
        }
        switch (values[0], values[1]) {
        case (127, _): return true                        // Loopback
        case (10, _): return true                         // 10.0.0.0/8
        case (192, 168): return true                      // 192.168.0.0/16
        case (169, 254): return true                      // Link-Local
        case (172, let second) where (16...31).contains(second): return true  // 172.16.0.0/12
        default: return false
        }
    }

    /// Ist diese IPv6-Adresse schon an sich selbst als heimnetz-intern zu
    /// erkennen? Globale Präfixe sind das nicht — die entscheidet
    /// `isLocalNetwork` anhand der eigenen Schnittstellen.
    static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }  // ::1
        if bytes[0] & 0xFE == 0xFC { return true }                       // fc00::/7
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }     // fe80::/10
        return false
    }

    /// Der IPv4-Teil einer IPv4-in-IPv6-Adresse ("::ffff:192.168.1.5") als Text.
    /// `nil` für jede andere Adresse — insbesondere für eine globale Adresse,
    /// die ihre letzten vier Bytes bloß mit Punkten schreibt.
    static func mappedIPv4(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16,
              bytes[0..<10].allSatisfy({ $0 == 0 }),
              bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
        return bytes[12..<16].map(String.init).joined(separator: ".")
    }
}
