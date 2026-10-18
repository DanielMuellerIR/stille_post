import ArgmaxCore
import Foundation
import StillePostClientCore
import WhisperKit

actor LocalWhisperAdapter: LocalModelLoading {
    private var engine: WhisperKit?
    private var busy = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func load(folder: URL) async throws {
        guard !busy, engine == nil else { throw LocalModelFailure.busy }
        busy = true; defer { completeOperation() }
        var candidate: WhisperKit?
        do {
            try Task.checkCancellation()
            let tokenizer = try await LocalWhisperTokenizer(folder: folder.appendingPathComponent("tokenizer"))
            candidate = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false,
                prewarm: false, load: false, download: false))
            candidate!.tokenizer = tokenizer
            candidate!.textDecoder.isModelMultilingual = true
            try Task.checkCancellation()
            try await candidate!.prewarmModels()
            try Task.checkCancellation()
            try await candidate!.loadModels()
            try Task.checkCancellation()
            engine = candidate
        } catch {
            if let candidate { await candidate.unloadModels() }
            if error is CancellationError { throw CancellationError() }
            throw LocalModelFailure.loading
        }
    }

    func unload() async {
        while busy { await withCheckedContinuation { idleWaiters.append($0) } }
        busy = true; defer { completeOperation() }
        let old = engine; engine = nil
        await old?.unloadModels()
    }

    // Der Adapter nimmt ausschließlich begrenzte PCM-Samples an. Aufnahme,
    // Segmentfolge und Ergebnisübernahme werden außerhalb dieses Adapters gesteuert.
    func recognize(samples: [Float], language: String) async throws -> String {
        guard !busy, let engine else { throw LocalModelFailure.missing }
        guard ["de", "en"].contains(language), !samples.isEmpty,
              samples.count <= 30 * WhisperKit.sampleRate, samples.allSatisfy(\.isFinite) else {
            throw LocalModelFailure.recognition
        }
        busy = true; defer { completeOperation() }
        do {
            try Task.checkCancellation()
            let results = try await engine.transcribe(audioArray: samples,
                decodeOptions: DecodingOptions(language: language, temperatureFallbackCount: 5, detectLanguage: false,
                    skipSpecialTokens: true, wordTimestamps: false, concurrentWorkerCount: 1))
            try Task.checkCancellation()
            return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError { throw CancellationError() }
        catch { throw LocalModelFailure.recognition }
    }

    private func completeOperation() {
        busy = false
        let waiting = idleWaiters; idleWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

// Tokenaufteilung nach Argmax WhisperKit (MIT, Copyright 2024–2026 Argmax Inc.).
// Lizenzhinweise: LocalModelLicenses.txt. Die lokale Factory verhindert den
// automatischen Hub-Rückfall des normalen SDK-Tokenizer-Ladepfads.
private final class LocalWhisperTokenizer: WhisperTokenizer {
    private let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(folder: URL) async throws {
        let loaded = try await AutoTokenizerWrapper.from(modelFolder: folder)
        base = loaded
        func token(_ value: String) throws -> Int {
            guard let id = loaded.convertTokenToId(value) else { throw LocalModelFailure.integrity }
            return id
        }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"), whitespaceToken: 220)
        let boundary = try token("<|endoftext|>")
        allLanguageTokens = Set(Constants.languages.values.compactMap { loaded.convertTokenToId("<|\($0)|>") }
            .filter { $0 > boundary })
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = [], groups: [[Int]] = [], pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let text = decode(tokens: pending)
            if text.contains("\u{fffd}") { continue }
            let punctuation = !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if words.isEmpty || text.hasPrefix(" ") || punctuation || pending[0] >= specialTokens.specialTokenBegin {
                words.append(text); groups.append(pending)
            } else {
                words[words.count - 1] += text; groups[groups.count - 1].append(contentsOf: pending)
            }
            pending.removeAll(keepingCapacity: true)
        }
        if !pending.isEmpty { words.append(decode(tokens: pending)); groups.append(pending) }
        return (words, groups)
    }
}
