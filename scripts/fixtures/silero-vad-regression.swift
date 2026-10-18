import Foundation
import CryptoKit
import StillePostCore

// Misst den Produktdetektor am unveränderten AP17-Korpus, ohne Netz oder Synthese.
@main struct ProductVadRegression {
    struct Item: Decodable {
        let id: String
        let wav: String
        let samples: Int
        let sha256: String
        let activity: [[Int]]
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        let corpus = try JSONDecoder().decode([Item].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var rows: [[String: Any]] = []
        for mode in Config.Vad.Detector.allCases {
            for item in corpus {
                let data = try Data(contentsOf: root.appendingPathComponent("audio/" + item.wav))
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256 else {
                    throw Check.failed("WAV-Hash: \(item.id)")
                }
                let samples = try AudioDecoder.samples16kMono(from: data)
                guard samples.count == item.samples else { throw Check.failed("Samplezahl") }
                var config = Config.Vad()
                config.detector = mode
                let started = ProcessInfo.processInfo.systemUptime
                let segmenter = await VadSegmenter.prepared(config: config, modelDirectory: model)
                guard segmenter.fallbackReason == nil else { throw Check.failed("Unerwarteter Rückfall") }
                var kept = [Bool](repeating: false, count: samples.count)
                var segments = 0
                // Originalsamples statt der Segmentierungsregel auswerten. Markierte
                // 30-ms-Aktivität muss in mindestens einem echten Ausgabesegment liegen.
                let original = floatData(samples)
                var cursor = 0, bufferStart = 0, preRollCount = 0
                var flushing = false
                let frameSize = mode == .silero ? 4096 : 480
                segmenter.onSegment = { segment in
                    let consumed = flushing ? cursor : cursor / frameSize * frameSize
                    defer {
                        preRollCount = min(4000, consumed - bufferStart)
                        bufferStart = consumed
                    }
                    guard segment.hadSpeech else { return }
                    segments += 1
                    let main = Array(segment.samples.dropFirst(preRollCount))
                    let search = bufferStart*4..<cursor*4
                    guard !main.isEmpty,
                          let range = original.range(of: floatData(main), in: search) else {
                        fatalError("Segment nicht dem Original zuordenbar: \(item.id)")
                    }
                    for i in range.lowerBound/4..<range.upperBound/4 { kept[i] = true }
                    if preRollCount > 0 {
                        for i in max(0, bufferStart-preRollCount)..<bufferStart { kept[i] = true }
                    }
                }
                for offset in stride(from: 0, to: samples.count, by: 320) {
                    cursor = min(samples.count, offset+320)
                    segmenter.process(Array(samples[offset..<cursor]))
                }
                flushing = true
                segmenter.flush()
                var total = 0, retained = 0
                for range in item.activity {
                    for i in range[0]..<range[1] { total += 1; if kept[i] { retained += 1 } }
                }
                let row: [String: Any] = ["mode": mode.rawValue, "id": item.id, "segments": segments,
                    "activeSamples": total, "retainedSamples": retained,
                    "seconds": ProcessInfo.processInfo.systemUptime-started]
                rows.append(row)
                if mode == .silero {
                    guard total == retained, total > 0 ? segments > 0 : segments == 0 else {
                        throw Check.failed("Retention/Störung: \(item.id) \(retained)/\(total), Segmente \(segments)")
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "rows": rows], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Produkt-VAD am festen Korpus bestanden")
    }
    static func floatData(_ samples: [Float]) -> Data { samples.withUnsafeBytes { Data($0) } }
    enum Check: Error { case failed(String) }
}
