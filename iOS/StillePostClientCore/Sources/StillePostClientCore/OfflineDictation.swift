import Foundation

public enum DictationMode: String, CaseIterable, Sendable { case mac, offline }
public enum DictationLanguage: String, CaseIterable, Sendable { case de, en }

@MainActor public protocol OfflineDictating: AnyObject {
    func transcribe(_ recording: Recording, language: DictationLanguage,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> String
}

public protocol LocalSpeechRecognizing: LocalModelLoading {
    func recognize(samples: [Float], language: String) async throws -> String
}

public enum OfflineSpeech {
    public static let sampleRate = 16_000
    public static let maxSamples = 181 * sampleRate

    // Die niedrige Schwelle erhält leise Sprache. Stationäres, stark wechselndes
    // Rauschen wird zusätzlich über Pegelverteilung/Nulldurchgänge abgewiesen.
    // Diese Signalvorauswahl ersetzt keinen Sprachklassifikator.
    public static func segments(_ samples: [Float]) throws -> [[Float]] {
        guard !samples.isEmpty else { throw ClientFailure.noAudio }
        guard samples.count <= maxSamples else { throw ClientFailure.recordingTooLarge }
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1.1 }) else { throw ClientFailure.noAudio }
        let frame = 320
        let features = stride(from: 0, to: samples.count, by: frame).map { start in
            let slice = samples[start..<min(start + frame, samples.count)]
            let energy = slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count)
            let crossings = zip(slice, slice.dropFirst()).reduce(0) { $0 + (($1.0 < 0) != ($1.1 < 0) ? 1 : 0) }
            return (energy: energy, crossings: crossings, count: slice.count)
        }
        let active = features.map { $0.energy >= 0.000001 }
        var output: [[Float]] = [], start = 0
        while start < samples.count {
            var end = min(start + 30 * sampleRate, samples.count)
            if end < samples.count {
                let lower = max(start + 27 * sampleRate, end - 3 * sampleRate) / frame
                if let quiet = (lower..<(end / frame)).reversed().first(where: { !active[$0] }) {
                    end = (quiet + 1) * frame
                }
            }
            let first = start / frame, last = min(active.count, (end + frame - 1) / frame)
            var run = 0, longest = 0, count = 0
            for index in first..<last {
                run = active[index] ? run + 1 : 0; longest = max(longest, run)
                if active[index] { count += 1 }
            }
            let speechFrames = (first..<last).filter { active[$0] }.map { features[$0] }
            let energies = speechFrames.map(\.energy).sorted()
            let crossings = speechFrames.reduce(0) { $0 + $1.crossings }
            let sampleCount = speechFrames.reduce(0) { $0 + $1.count }
            if !energies.isEmpty, Double(crossings) / Double(max(1, sampleCount)) > 0.35,
               energies[Int(Double(energies.count) * 0.9)] < energies[Int(Double(energies.count) * 0.1)] * 1.69 {
                start = end; continue
            }
            if longest >= 3, count >= 5 {
                // Randstille erhalten: Ihr Beschnitt ließ kurze Nein/No-Antworten
                // im echten Modell als leeres Ergebnis enden.
                output.append(Array(samples[start..<end]))
            }
            start = end
        }
        return output
    }

    public static func join(_ parts: [String]) -> String {
        var text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        if let last = text.unicodeScalars.last, CharacterSet.alphanumerics.contains(last) { text += "." }
        return text
    }
}
