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

        let reader = try FileReader(url: temporaryURL, maxSampleCount: maxSampleCount)
        var samples: [Float] = []
        samples.reserveCapacity(reader.estimatedSampleCount)
        while let chunk = try reader.read() { samples.append(contentsOf: chunk) }
        guard !samples.isEmpty else { throw DecodeError.empty }
        return samples
    }

    /// Ein Leser gehört genau einem Auftrag. Die Brücke sammelt seine begrenzten
    /// Blöcke, Dateiimporte schreiben sie ohne vollständige Float-Kopie auf Platte.
    final class FileReader {
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let inputFormat: AVAudioFormat
        private let outputFormat: AVAudioFormat
        private let maximum: Int
        private let chunkFrames: AVAudioFrameCount = 16384
        private var inputExhausted = false
        private var ended = false
        private(set) var sampleCount = 0
        let estimatedSampleCount: Int
        let estimatedDuration: TimeInterval?

        init(url: URL, maxSampleCount: Int) throws {
            try Task.checkCancellation()
            do { file = try AVAudioFile(forReading: url) }
            catch { throw DecodeError.unsupported(error.localizedDescription) }
            inputFormat = file.processingFormat
            guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: output) else {
                throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
            }
            outputFormat = output; self.converter = converter
            maximum = min(AudioDecoder.maxSampleCount, max(0, maxSampleCount))
            let duration = Double(file.length) / inputFormat.sampleRate
            estimatedDuration = duration.isFinite && duration >= 0 ? duration : nil
            // Containerlängen können falsch sein. Vor Int-Konvertierung kappen;
            // die tatsächliche Grenze wird zusätzlich nach jedem Block geprüft.
            let estimated = duration * 16000 + 16000
            estimatedSampleCount = Int(estimated.isFinite ? min(max(estimated, 0), Double(maximum)) : 0)
        }

        func read() throws -> [Float]? {
            while !ended {
                try Task.checkCancellation()
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunkFrames) else {
                    throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
                }
                var conversionError: NSError?
                var readError: Error?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if self.inputExhausted { inputStatus.pointee = .endOfStream; return nil }
                    guard let input = AVAudioPCMBuffer(pcmFormat: self.inputFormat, frameCapacity: self.chunkFrames) else {
                        readError = DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
                        self.inputExhausted = true; inputStatus.pointee = .endOfStream; return nil
                    }
                    do { try self.file.read(into: input) }
                    catch {
                        // AVAudioFile liefert am regulären Ende teils Code 0.
                        // Ein Fehler vor der angekündigten Länge ist Datenverlust.
                        if self.file.framePosition < self.file.length { readError = error }
                        self.inputExhausted = true; inputStatus.pointee = .endOfStream; return nil
                    }
                    guard input.frameLength > 0 else {
                        self.inputExhausted = true; inputStatus.pointee = .endOfStream; return nil
                    }
                    inputStatus.pointee = .haveData
                    return input
                }
                try Task.checkCancellation()
                if let readError { throw DecodeError.unsupported(readError.localizedDescription) }
                if let conversionError { throw DecodeError.unsupported(conversionError.localizedDescription) }
                if status == .error { throw DecodeError.unsupported(L10n.text("core.bridge.audio_format")) }
                ended = status == .endOfStream || (output.frameLength == 0 && inputExhausted)
                if output.frameLength > 0 {
                    guard let channel = output.floatChannelData?[0] else {
                        throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
                    }
                    let count = Int(output.frameLength)
                    guard count <= maximum - sampleCount else {
                        throw DecodeError.tooLong(seconds: maximum / 16000)
                    }
                    sampleCount += count
                    let samples = Array(UnsafeBufferPointer(start: channel, count: count))
                    guard samples.allSatisfy(\.isFinite) else {
                        throw DecodeError.unsupported(L10n.text("core.bridge.audio_format"))
                    }
                    return samples
                }
            }
            return nil
        }
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
