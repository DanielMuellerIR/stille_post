import Network
import Security
import CryptoKit
import XCTest
@testable import StillePostCore


final class BridgeInputTests: XCTestCase {
    // MARK: - Konfiguration

    func testBridgeIsOffByDefaultAndValidatesItsRanges() throws {
        var config = Config()
        XCTAssertFalse(config.bridge.enabled, "Ein offener Port darf keine Voreinstellung sein")
        XCTAssertNoThrow(try config.validate())

        config.bridge.port = 80          // unter 1024: bräuchte Root-Rechte
        XCTAssertThrowsError(try config.validate())
        config.bridge.port = 8188
        config.bridge.maxRequestMegabytes = 0
        XCTAssertThrowsError(try config.validate())
    }

    func testBrokenBridgeValuesFallBackFieldByField() throws {
        let json = """
        {"bridge": {"enabled": true, "port": 70000, "maxRequestMegabytes": 40}}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(config.bridge.enabled, "gültige Nachbarfelder bleiben erhalten")
        XCTAssertEqual(config.bridge.port, Config.Bridge().port, "kaputter Port -> Default")
        XCTAssertEqual(config.bridge.maxRequestMegabytes, 40)
    }

    // MARK: - Audio

    func testAudioFormatIsRecognizedFromTheFirstBytes() {
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("RIFF....WAVEfmt ".utf8)), "wav")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("....ftypM4A ".utf8)), "m4a")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("OggS".utf8)), "ogg")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("ID3".utf8)), "mp3")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data([0xFF, 0xFB, 0x90])), "mp3")
        XCTAssertEqual(AudioDecoder.fileExtension(for: Data("irgendwas".utf8)), "audio")
    }

    func testDecoderTurnsWavIntoSixteenKilohertzMono() throws {
        // Eine Sekunde Sinuston bei 44,1 kHz -> muss auf 16 kHz mono landen.
        let sampleRate = 44100
        var samples = [Float]()
        for index in 0..<sampleRate {
            samples.append(sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.5)
        }
        let wav = wavData(from: samples, sampleRate: sampleRate)
        let decoded = try AudioDecoder.samples16kMono(from: wav)
        // Rundungen des Umwandlers zulassen, aber die Größenordnung festnageln.
        XCTAssertEqual(Double(decoded.count), 16000, accuracy: 500)
        XCTAssertTrue(decoded.contains { abs($0) > 0.1 }, "Signal darf nicht verschwinden")
    }

    func testDecoderEnforcesTheLengthLimit() throws {
        // Zwei Sekunden Audio gegen ein (nur im Test) auf eine Sekunde gesetztes
        // Limit: Die Grenze muss greifen, bevor der Speicher verbraucht ist.
        let sampleRate = 16000
        let samples = [Float](repeating: 0.25, count: sampleRate * 2)
        let wav = wavData(from: samples, sampleRate: sampleRate)
        XCTAssertThrowsError(try AudioDecoder.samples16kMono(from: wav,
                                                             maxSampleCount: sampleRate)) { error in
            guard case AudioDecoder.DecodeError.tooLong = error else {
                return XCTFail("erwartet tooLong, war: \(error)")
            }
        }
        // Dieselbe Datei ohne Test-Limit bleibt gültig.
        XCTAssertNoThrow(try AudioDecoder.samples16kMono(from: wav))
    }

    func testDecoderTreatsMidFileReadErrorAsErrorNotAsShortSuccess() throws {
        // Kaputte Aufnahme: Ein m4a, dessen hintere Audiodaten zerstört sind,
        // liefert erst gültige Frames und dann einen Lesefehler mitten in der
        // Datei. Das darf KEIN stiller Teilerfolg werden — sonst würde
        // abgeschnittenes Audio kommentarlos transkribiert und als Erfolg
        // gemeldet (frühere Lücke: Lesefehler galten pauschal als Dateiende).
        let converter = URL(fileURLWithPath: "/usr/bin/afconvert")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: converter.path),
                          "afconvert nicht verfügbar")

        // 1 s Sinuston als WAV, mit afconvert nach AAC/m4a gewandelt.
        let sampleRate = 44100
        var samples = [Float]()
        for index in 0..<sampleRate {
            samples.append(sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.5)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillepost-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("ton.wav")
        let m4aURL = directory.appendingPathComponent("ton.m4a")
        try wavData(from: samples, sampleRate: sampleRate).write(to: wavURL)
        let convert = Process()
        convert.executableURL = converter
        convert.arguments = ["-f", "m4af", "-d", "aac", wavURL.path, m4aURL.path]
        try convert.run()
        convert.waitUntilExit()
        try XCTSkipUnless(convert.terminationStatus == 0, "afconvert fehlgeschlagen")

        // Erst der Gegenbeweis: Die unveränderte Datei muss sauber dekodieren.
        // Ohne ihn belegt der Test unten nur, dass irgendetwas an der Datei
        // kaputt ist — nicht, dass der Lesefehler-Pfad greift.
        let intact = try Data(contentsOf: m4aURL)
        XCTAssertFalse(try AudioDecoder.samples16kMono(from: intact).isEmpty)

        // Hinteres Drittel der Audiodaten zerstören — aber nur INNERHALB des
        // mdat-Atoms. Bis ans Dateiende zu schreiben träfe auch das dahinter
        // liegende moov-Atom mit der Pakettabelle; dann scheiterte schon das
        // Öffnen, und der zu prüfende Fehlerpfad MITTEN im Lesen käme nie dran.
        var m4a = intact
        let tag = try XCTUnwrap(m4a.range(of: Data("mdat".utf8)))
        try XCTSkipUnless(tag.lowerBound >= 4, "mdat ohne vorangestelltes Größenfeld")
        // Vor dem Atomnamen stehen vier Bytes Atomgröße (Big Endian).
        let sizeField = tag.lowerBound - 4
        let atomSize = Int(m4a[sizeField..<tag.lowerBound]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        try XCTSkipUnless(atomSize > 8 && sizeField + atomSize <= m4a.count,
                          "unerwartete mdat-Größe (64-Bit-Variante?)")
        let payload = tag.upperBound..<(sizeField + atomSize)
        for index in (payload.lowerBound + payload.count * 2 / 3)..<payload.upperBound {
            m4a[index] = 0xAA
        }

        XCTAssertThrowsError(try AudioDecoder.samples16kMono(from: m4a)) { error in
            guard case AudioDecoder.DecodeError.unsupported = error else {
                return XCTFail("erwartet unsupported, war: \(error)")
            }
        }
    }

    func testDecoderRejectsGarbageAndEmptyInput() {
        XCTAssertThrowsError(try AudioDecoder.samples16kMono(from: Data()))
        XCTAssertThrowsError(try AudioDecoder.samples16kMono(
            from: Data(repeating: 0x41, count: 4096)
        ))
    }

    /// Minimaler WAV-Schreiber für den Test (16 Bit, mono, freie Abtastrate).
    /// Der Kern-Schreiber `WavCodec` kann nur 16 kHz — hier brauchen wir aber
    /// bewusst eine andere Rate, damit die Umrechnung überhaupt etwas tut.
    private func wavData(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteCount = samples.count * 2
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func append32(_ value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)) }
        func append16(_ value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)) }
        append("RIFF"); append32(36 + byteCount); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(byteCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.append(contentsOf: withUnsafeBytes(of: Int16(clamped * 32767).littleEndian, Array.init))
        }
        return data
    }
}
