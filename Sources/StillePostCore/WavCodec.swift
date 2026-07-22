import Foundation

/// Hilfsfunktionen rund um das WAV-Dateiformat.
///
/// Wir arbeiten intern überall mit 16 kHz, mono, Float-Samples (-1...1) — das ist
/// genau das Format, das Whisper erwartet. Für den Versand an den whisper-server
/// und fürs Speichern auf Platte wandeln wir in 16-Bit-PCM-WAV um.
public enum WavCodec {

    /// Die Sample-Rate, mit der die gesamte Pipeline arbeitet.
    public static let sampleRate = 16_000

    /// Baut eine komplette WAV-Datei (Header + Daten) im Speicher aus Float-Samples.
    /// 16-Bit PCM, mono, 16 kHz — kompakt genug, um Segmente per HTTP zu verschicken.
    public static func wavData(from samples: [Float]) -> Data {
        // Float (-1...1) in 16-Bit-Ganzzahlen umrechnen (mit Begrenzung gegen Übersteuerung).
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        return wavHeader(dataByteCount: pcm.count) + pcm
    }

    /// Baut den 44-Byte-Standard-WAV-Header für 16-Bit-PCM mono.
    static func wavHeader(dataByteCount: Int) -> Data {
        var header = Data()
        func append(_ string: String) { header.append(contentsOf: string.utf8) }
        func append32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }

        let byteRate = UInt32(sampleRate * 2)  // sampleRate * Kanäle(1) * BytesProSample(2)

        append("RIFF")
        append32(UInt32(36 + dataByteCount))   // Restgröße der Datei nach diesem Feld
        append("WAVE")
        append("fmt ")
        append32(16)                           // Länge des fmt-Blocks
        append16(1)                            // Audioformat 1 = PCM
        append16(1)                            // 1 Kanal (mono)
        append32(UInt32(sampleRate))
        append32(byteRate)
        append16(2)                            // Block-Align: Kanäle * BytesProSample
        append16(16)                           // Bits pro Sample
        append("data")
        append32(UInt32(dataByteCount))
        return header
    }

}

/// Schreibt eine WAV-Datei fortlaufend auf Platte, während die Aufnahme läuft.
///
/// Der WAV-Header enthält die Gesamtlänge — die kennen wir erst am Ende. Deshalb
/// schreiben wir zuerst einen Platzhalter-Header und tragen die echten Längen beim
/// `finish()` nach. So ist die Datei nach jedem Diktat sofort gültig, und bei einem
/// Absturz mitten in der Aufnahme sind die Audio-Daten trotzdem noch da.
public final class WavFileWriter {
    private let handle: FileHandle
    private let lock = NSLock()
    /// Testgrenze für reproduzierbare Schreibfehler. Der Zähler ist 0 für den
    /// Platzhalter-Header, 1 für den ersten Sample-Block usw.
    private let beforeWrite: ((Int) throws -> Void)?
    private var writeCount = 0
    private var dataBytes = 0
    private var firstError: Error?
    private var isFinished = false
    public let url: URL

    public convenience init(url: URL) throws {
        try self.init(url: url, beforeWrite: nil)
    }

    init(url: URL, beforeWrite: ((Int) throws -> Void)?) throws {
        self.url = url
        self.beforeWrite = beforeWrite
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        // Platzhalter-Header (Längenfelder 0) — wird in finish() korrigiert.
        try beforeWrite?(0)
        try handle.write(contentsOf: WavCodec.wavHeader(dataByteCount: 0))
        writeCount = 1
    }

    /// Hängt Float-Samples als 16-Bit-PCM an die Datei an.
    public func append(_ samples: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
        guard !isFinished else { throw WriterError.alreadyFinished }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        do {
            try beforeWrite?(writeCount)
            try handle.write(contentsOf: pcm)
            writeCount += 1
            dataBytes += pcm.count
        } catch {
            firstError = error
            throw error
        }
    }

    /// Trägt die echten Längen in den Header ein und schließt die Datei.
    /// Ein früherer Append-Fehler wird nach dem bestmöglichen Finalisieren erneut
    /// geworfen. Dadurch kann der Audio-Thread weiterlaufen, aber `stop()` meldet
    /// den ersten Datenverlust zuverlässig und verwendet die Datei nicht für Retry.
    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        if isFinished {
            if let firstError { throw firstError }
            return
        }
        var finishError = firstError
        do {
            try handle.seek(toOffset: 0)
            try beforeWrite?(writeCount)
            try handle.write(contentsOf: WavCodec.wavHeader(dataByteCount: dataBytes))
            writeCount += 1
        } catch {
            if finishError == nil { finishError = error }
        }
        do {
            try handle.close()
        } catch {
            if finishError == nil { finishError = error }
        }
        isFinished = true
        firstError = finishError
        if let finishError { throw finishError }
    }

    enum WriterError: Error {
        case alreadyFinished
    }
}
