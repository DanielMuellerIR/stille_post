import XCTest
@testable import StillePostCore

final class WavCodecTests: XCTestCase {
    // MARK: WAV

    func testWavEncodingProducesExpectedHeaderAndSamples() throws {
        let original: [Float] = (0..<1600).map { 0.8 * sin(Float($0) * 0.05) }
        let data = WavCodec.wavData(from: original)
        XCTAssertEqual(data.count, 44 + original.count * 2, "Header 44 Bytes + 2 Bytes pro Sample")
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(wavUInt32(data, at: 40), UInt32(original.count * 2))
        let restored = wavSamples(data)
        XCTAssertEqual(restored.count, original.count)
        for (a, b) in zip(original, restored) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
    }

    func testWavFileWriterProducesReadableFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url)
        try writer.append([Float](repeating: 0.5, count: 800))
        try writer.append([Float](repeating: -0.5, count: 800))
        try writer.finish()

        let restored = wavSamples(try Data(contentsOf: url))
        XCTAssertEqual(restored.count, 1600)
        XCTAssertEqual(restored[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(restored[1599], -0.5, accuracy: 0.001)
    }

    func testDiskAndNetworkWavCarryTheSameBytes() throws {
        // Dasselbe Audio geht auf zwei Wegen weiter: als WAV per HTTP an den
        // whisper-server und fortlaufend als Datei auf Platte. „Erneut
        // transkribieren“ liest später die Datei — sie muss genau das Audio
        // enthalten, das das Live-Diktat schon gesehen hat. Beide Wege benutzen
        // deshalb dieselbe Umrechnung; dieser Test hält sie zusammen.
        let samples: [Float] = [0, 0.5, -0.5, 0.123, -0.987,
                                1, -1, 2, -2]  // die letzten vier prüfen die Begrenzung
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-parity-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url)
        try writer.append(samples)
        try writer.finish()

        XCTAssertEqual(try Data(contentsOf: url), WavCodec.wavData(from: samples),
                       "Datei und Netz-WAV müssen Byte für Byte übereinstimmen")
    }

    func testPcmConversionSurvivesNaNAndInfinity() {
        // Die Umrechnung laeuft auf dem Audio-Thread, und `Int16(x)` bricht hart
        // ab, sobald x ausserhalb des Wertebereichs liegt oder keine Zahl ist. Die
        // Begrenzung `max(-1, min(1, sample))` faengt beides ab — auch NaN, weil
        // jeder Vergleich mit NaN falsch ist und `min`/`max` deshalb den anderen
        // Wert nehmen. Das ist nicht offensichtlich: Wer die beiden Aufrufe
        // umdreht oder durch eine andere Begrenzung ersetzt, holt sich einen
        // Absturz mitten in der Aufnahme zurueck. Deshalb steht es hier fest.
        let samples: [Float] = [.nan, .infinity, -.infinity, .signalingNaN,
                                .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let data = WavCodec.wavData(from: samples)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        let restored = wavSamples(data)
        // NaN und +unendlich landen am oberen Anschlag, -unendlich am unteren.
        XCTAssertEqual(restored[0], 1, accuracy: 0.001, "NaN muss begrenzt werden")
        XCTAssertEqual(restored[1], 1, accuracy: 0.001)
        XCTAssertEqual(restored[2], -1, accuracy: 0.001)
        XCTAssertEqual(restored[3], 1, accuracy: 0.001, "auch signalisierendes NaN")
        XCTAssertEqual(restored[4], 1, accuracy: 0.001)
        XCTAssertEqual(restored[5], -1, accuracy: 0.001)
    }

    func testWavFileWriterRetainsAndReportsFirstAppendFailure() throws {
        enum Expected: Error { case diskFull }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-fail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavFileWriter(url: url) { writeIndex in
            if writeIndex == 1 { throw Expected.diskFull }
        }

        XCTAssertThrowsError(try writer.append([0.5]))
        XCTAssertThrowsError(try writer.append([0.25]))
        XCTAssertThrowsError(try writer.finish())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

private func wavUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

/// Decoder nur für Byte-Level-Tests des tatsächlich hochgeladenen WAV-Formats;
/// Produktcode lädt Retry-Dateien unverändert als `Data` und braucht keinen zweiten
/// Decoder-Pfad.
private func wavSamples(_ data: Data) -> [Float] {
    stride(from: 44, to: data.count - 1, by: 2).map { offset in
        let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        return Float(Int16(bitPattern: bits)) / 32767
    }
}
