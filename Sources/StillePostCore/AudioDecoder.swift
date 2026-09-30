import AVFoundation
import Foundation

/// Wandelt beliebiges Audio in genau das Format um, das Whisper erwartet:
/// 16 kHz, mono, Float32.
///
/// Gebraucht für die Netzwerk-Brücke: Die Kurzbefehle-App des iPhones nimmt in
/// AAC (`.m4a`) auf, der whisper-server versteht aber nur WAV. Die Umwandlung
/// gehört auf den Mac, damit die Gegenseite so einfach wie möglich bleibt — ein
/// Kurzbefehl kann kein Audio umkodieren.
public enum AudioDecoder {

    /// Kleinste Anzahl Bytes, bei der eine Umwandlung überhaupt versucht wird.
    /// Kürzer ist garantiert kein Audio, sondern ein Bedienfehler.
    private static let minimumBytes = 64

    /// Harte Obergrenze der dekodierten Länge: eine Stunde Audio (16 kHz mono).
    /// Das Brückenlimit begrenzt nur die KOMPRIMIERTEN Request-Bytes — eine
    /// stark komprimierte oder manipulierte Datei könnte sonst beliebig viele
    /// Samples (und damit Speicher) erzeugen.
    public static let maxSampleCount = 16000 * 3600

    /// Dekodiert Audio-Bytes zu 16-kHz-Mono-Samples. `maxSampleCount` ist nur
    /// für Tests übersteuerbar; Produktivpfade nutzen die Stunden-Grenze.
    public static func samples16kMono(
        from data: Data, maxSampleCount: Int = AudioDecoder.maxSampleCount
    ) throws -> [Float] {
        try Task.checkCancellation()
        guard data.count >= minimumBytes else { throw DecodeError.empty }

        // AVFoundation liest nur aus Dateien, nicht aus dem Speicher. Die
        // Zwischendatei wird in jedem Fall wieder gelöscht — auch im Fehlerfall.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillepost-bridge-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension(for: data))
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: temporaryURL)
        } catch {
            throw DecodeError.unsupported(error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
        }

        var samples: [Float] = []
        // Grobe Vorausschau auf die Zielgröße, damit das Array nicht ständig
        // wächst — gekappt auf die harte Obergrenze, damit eine gelogene
        // Container-Länge keine Riesen-Reservierung auslösen kann.
        //
        // Die Kappung passiert bewusst NOCH IN `Double`: `file.length` kommt aus
        // dem Container und darf gelogen sein. Bei einer absurden Länge (oder
        // einer Abtastrate 0, die `inf` ergibt) würde `Int(...)` abstürzen,
        // bevor `min` überhaupt greift — der Prozess wäre weg, statt sauber
        // `tooLong` zu melden.
        let estimated = Double(file.length) * 16000 / inputFormat.sampleRate + 16000
        let capped = estimated.isFinite ? min(max(estimated, 0), Double(maxSampleCount)) : 0
        samples.reserveCapacity(Int(capped))

        let chunkFrames: AVAudioFrameCount = 16384
        var inputExhausted = false
        // Lesefehler aus dem Eingabe-Closure hier festhalten: `convert` meldet
        // sie nicht zuverlässig selbst, und ein Lesefehler darf nicht wie ein
        // normales Dateiende aussehen — sonst würde still abgeschnittenes Audio
        // als Erfolg transkribiert.
        var readError: Error?
        while true {
            try Task.checkCancellation()
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkFrames) else {
                throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
            }
            var conversionError: NSError?
            // Der Umwandler holt sich seine Eingabe selbst häppchenweise. Das ist
            // der einzige Weg, der auch die Abtastrate ändern darf (44,1 -> 16 kHz).
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if inputExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
                    inputExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input)
                } catch {
                    // AVAudioFile wirft am REGULÄREN Dateiende teils einen
                    // inhaltsleeren Fehler (Code 0). Nur wenn die Leseposition
                    // noch vor der angekündigten Länge liegt, ist es ein echter
                    // Lesefehler — etwa eine abgeschnittene Datei.
                    if file.framePosition < file.length {
                        readError = error
                    }
                    inputExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if input.frameLength == 0 {
                    inputExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            try Task.checkCancellation()
            if let readError {
                throw DecodeError.unsupported(readError.localizedDescription)
            }
            if let conversionError {
                throw DecodeError.unsupported(conversionError.localizedDescription)
            }
            if status == .error {
                // `.error` ohne gesetzten NSError darf trotzdem kein stiller
                // Teilerfolg werden.
                throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
            }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel,
                                                              count: Int(output.frameLength)))
                // Obergrenze bei jedem Häppchen erzwingen, nicht erst am Ende —
                // sonst wäre der Speicher schon verbraucht, bevor es kracht.
                guard samples.count <= maxSampleCount else {
                    throw DecodeError.tooLong(seconds: maxSampleCount / 16000)
                }
            }
            if status == .endOfStream { break }
            if output.frameLength == 0 && inputExhausted { break }
        }

        guard !samples.isEmpty else { throw DecodeError.empty }
        return samples
    }

    /// Rät die Dateiendung aus den ersten Bytes. AVFoundation erkennt das Format
    /// zwar am Inhalt, aber eine passende Endung erspart Sonderfälle bei
    /// Containern, die sich sonst leicht verwechseln lassen.
    static func fileExtension(for data: Data) -> String {
        func matches(_ ascii: String, at offset: Int) -> Bool {
            let bytes = Array(ascii.utf8)
            guard data.count >= offset + bytes.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            return Array(data[start..<data.index(start, offsetBy: bytes.count)]) == bytes
        }
        if matches("RIFF", at: 0) { return "wav" }
        if matches("ftyp", at: 4) { return "m4a" }
        if matches("OggS", at: 0) { return "ogg" }
        if matches("fLaC", at: 0) { return "flac" }
        if matches("caff", at: 0) { return "caf" }
        if matches("ID3", at: 0) { return "mp3" }
        if data.count >= 2, data[data.startIndex] == 0xFF,
           data[data.index(after: data.startIndex)] & 0xE0 == 0xE0 {
            return "mp3"
        }
        // Unbekannt: ohne Endung versuchen — AVFoundation schaut dann in den Inhalt.
        return "audio"
    }

    public enum DecodeError: Error, LocalizedError {
        case empty
        case unsupported(String)
        case tooLong(seconds: Int)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return L10n.text("core.bridge.audio_empty")
            case .unsupported(let detail):
                return L10n.format("core.bridge.audio_unsupported", detail)
            case .tooLong(let seconds):
                return L10n.format("core.bridge.audio_too_long", String(seconds / 60))
            }
        }
    }
}
