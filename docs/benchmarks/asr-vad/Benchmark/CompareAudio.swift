import Foundation
import CoreML
import Darwin
import FluidAudio
import StillePostCore

struct AudioCase: Decodable {
    let id: String
    let wav: String
    let segments: [String]
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

func save(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

func loadSamples(_ url: URL) throws -> [Float] {
    try AudioConverter().resampleAudioFile(url)
}

func floatData(_ samples: [Float]) -> Data {
    samples.withUnsafeBytes { Data($0) }
}

@main struct CompareAudio {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3, ["gate", "parakeet", "silero", "rms"].contains(args[1]) else {
            throw NSError(domain: "CompareAudio mode work [cold]", code: 1)
        }
        let mode = args[1]
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let modelRoot = root.appendingPathComponent("models")
        let started = now()
        let cases = try JSONDecoder().decode([AudioCase].self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard !cases.isEmpty else { throw NSError(domain: "Empty corpus", code: 3) }
        var asr: AsrManager?
        var vad: VadManager?
        if mode == "parakeet" {
            let models = try AsrModels.loadLocal(from: modelRoot, version: .v3, encoderPrecision: .int8)
            asr = AsrManager()
            try await asr!.loadModels(models)
        } else if mode == "silero" || mode == "gate" {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: modelRoot.appendingPathComponent(
                "silero-vad-unified-256ms-v6.2.1.mlmodelc"), configuration: config)
            vad = VadManager(vadModel: model)
        }
        if mode == "gate" {
            let result = try await vad!.process(Array(repeating: Float(0.001), count: 4096))
            guard result.count == 1, result[0].probability.isFinite else {
                throw NSError(domain: "Invalid VAD", code: 2)
            }
            try save(["passed": true, "seconds": now()-started,
                      "probability": result[0].probability, "peakRSSBytes": peakRSS()],
                     to: root.appendingPathComponent("gate.json"))
            return
        }
        let initSeconds = now()-started
        let cold = args.dropFirst(3).contains("cold")
        var rows: [[String: Any]] = []
        if let asr, !cold {
            var state = try TdtDecoderState()
            _ = try await asr.transcribe(root.appendingPathComponent("audio/"+cases[0].segments[0]), decoderState: &state)
        }
        if let vad, !cold {
            _ = try await vad.process(loadSamples(root.appendingPathComponent("audio/"+cases[0].wav)))
        }
        let vadAudio = root.appendingPathComponent("vad-audio")
        try FileManager.default.createDirectory(at: vadAudio, withIntermediateDirectories: true)
        for repeatIndex in 0..<(cold ? 1 : 3) {
            for item in (cold ? Array(cases.prefix(1)) : cases) {
                let begin = now()
                var row: [String: Any] = ["id": item.id, "repeat": repeatIndex,
                    "phase": cold ? "process-cold" : "warm"]
                if let asr {
                    var texts: [String] = []
                    for segment in item.segments {
                        var state = try TdtDecoderState()
                        let result = try await asr.transcribe(root.appendingPathComponent("audio/"+segment), decoderState: &state)
                        texts.append(result.text)
                    }
                    row["text"] = texts.joined(separator: " ")
                    row["segmentTexts"] = texts
                } else {
                    let samples = try loadSamples(root.appendingPathComponent("audio/"+item.wav))
                    var ranges: [[Int]] = []
                    var pieces: [[Float]] = []
                    if let vad {
                        let spans = try await vad.segmentSpeech(samples, config: VadSegmentationConfig(
                            minSpeechDuration: 0.25, minSilenceDuration: 0.7,
                            maxSpeechDuration: 30, speechPadding: 0.25))
                        for span in spans {
                            let a = max(0, span.startSample(sampleRate: 16000))
                            let b = min(samples.count, span.endSample(sampleRate: 16000))
                            ranges.append([a,b]); pieces.append(Array(samples[a..<b]))
                        }
                    } else {
                        let detector = VadSegmenter(config: Config.Vad())
                        let source = floatData(samples)
                        var cursor = 0
                        var bufferStart = 0
                        var previousPreRoll = 0
                        var mappingFailed = false
                        detector.onSegment = { segment in
                            if segment.hadSpeech {
                                // Ohne Vorlauf ist der gekürzte Hauptteil ein exakter
                                // Ausschnitt des Originals. So bleiben Grenzen messbar,
                                // ohne den Produktdetektor nachzuimplementieren.
                                let main = Array(segment.samples.dropFirst(previousPreRoll))
                                if !main.isEmpty, let found = source.range(of: floatData(main)) {
                                    ranges.append([found.lowerBound/4, found.upperBound/4])
                                    if previousPreRoll > 0 {
                                        ranges.append([max(0,bufferStart-previousPreRoll),bufferStart])
                                    }
                                } else { mappingFailed = true }
                                pieces.append(segment.samples)
                            }
                            previousPreRoll = min(4000,cursor-bufferStart)
                            bufferStart = cursor
                        }
                        for offset in stride(from: 0, to: samples.count, by: 480) {
                            cursor = min(samples.count,offset+480)
                            detector.process(Array(samples[offset..<cursor]))
                        }
                        detector.flush()
                        guard !mappingFailed else { throw NSError(domain: "RMS range mapping", code: 4) }
                    }
                    var files: [String] = []
                    if repeatIndex == 0 {
                        for (index, piece) in pieces.enumerated() {
                            let name = "\(mode)-\(item.id)-\(index).wav"
                            try WavCodec.wavData(from: piece).write(to: vadAudio.appendingPathComponent(name))
                            files.append(name)
                        }
                    }
                    row["ranges"] = ranges
                    row["segmentCount"] = pieces.count
                    row["files"] = files
                }
                row["seconds"] = now()-begin
                row["peakRSSBytes"] = peakRSS()
                rows.append(row)
            }
        }
        let output = cold ? "\(mode)-cold-\(getpid()).json" : "\(mode).json"
        try save(["engine": mode, "initSeconds": initSeconds, "rows": rows,
                  "totalSeconds": now()-started, "peakRSSBytes": peakRSS()],
                 to: root.appendingPathComponent(output))
        await asr?.cleanup()
    }
}
