import Foundation

/// HTTP-Client für den lokalen whisper-server (whisper.cpp).
///
/// Der Server läuft dauerhaft und hält das Whisper-Modell warm im Speicher —
/// dadurch kostet eine Transkription nur die reine Rechenzeit (Bruchteile einer
/// Sekunde pro Segment), nie das Laden des Modells.
public final class WhisperClient {

    private let config: Config.Whisper
    private let session: URLSession

    public init(config: Config.Whisper) {
        self.config = config
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 300  // sehr lange Aufnahmen abdecken
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Transkribiert Audio-Samples (16 kHz mono Float) zu Text.
    public func transcribe(samples: [Float]) async throws -> String {
        try await transcribe(wavData: WavCodec.wavData(from: samples))
    }

    /// Transkribiert eine fertige WAV-Datei (für "Erneut transkribieren" im Verlauf).
    public func transcribe(wavFile: URL) async throws -> String {
        try await transcribe(wavData: try Data(contentsOf: wavFile))
    }

    private func transcribe(wavData: Data) async throws -> String {
        guard let url = URL(string: "\(config.serverURL)/inference") else {
            throw WhisperError.badConfig("Ungültige whisper-server-URL: \(config.serverURL)")
        }

        // Multipart-Request von Hand bauen (kein externes Paket nötig):
        // ein Datei-Feld "file" plus einfache Textfelder.
        let boundary = "stillepost-\(UUID().uuidString)"
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wavData)
        body.append(Data("\r\n".utf8))
        addField("response_format", "json")
        addField("temperature", "0")
        if config.language != "auto" {
            addField("language", config.language)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WhisperError.serverError(body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw WhisperError.badResponse
        }
        return Self.cleanWhisperArtifacts(text)
    }

    /// Prüft, ob der whisper-server erreichbar ist.
    public func isReachable() async -> Bool {
        guard let url = URL(string: config.serverURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        // Jede HTTP-Antwort (auch 404) heißt: Server-Prozess lebt.
        return (try? await session.data(for: request)) != nil
    }

    /// Entfernt bekannte Whisper-Artefakte: Marker wie [Musik], (Räuspern) und
    /// typische Halluzinations-Phrasen, die Whisper bei (Rest-)Stille erfindet.
    static func cleanWhisperArtifacts(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Marker in eckigen/runden Klammern am Stück entfernen, z. B. "[Musik]", "(Applaus)".
        for pattern in [#"\[[^\]]{1,40}\]"#, #"\([^)]{1,40}\)"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // Bekannte Stille-Halluzinationen (ganze Ausgabe besteht nur daraus -> leer).
        let hallucinations = [
            "untertitel im auftrag des zdf für funk, 2017",
            "untertitel von stephanie geiges",
            "untertitelung des zdf, 2020",
            "untertitelung. br 2018",
            "vielen dank für's zuschauen",
            "vielen dank fürs zuschauen",
            "das war's für heute",
            "bis zum nächsten mal",
            "thanks for watching",
            "copyright wdr",
        ]
        let normalized = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if hallucinations.contains(where: { normalized == $0 }) {
            return ""
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum WhisperError: Error, LocalizedError {
        case badConfig(String)
        case serverError(body: String)
        case badResponse
        public var errorDescription: String? {
            switch self {
            case .badConfig(let detail): return detail
            case .serverError(let body): return "whisper-server-Fehler: \(String(body.prefix(300)))"
            case .badResponse: return "Unerwartetes Antwortformat vom whisper-server"
            }
        }
    }
}
