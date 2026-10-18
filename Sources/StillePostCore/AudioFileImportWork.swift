import Foundation

public struct AudioImportLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumSeconds: Int
    public static let shortClip = Self(maximumBytes: 50 * 1024 * 1024, maximumSeconds: 300)
}

public enum AudioImportStage: Equatable, Sendable { case decoding, transcribing, cleaning }

enum AudioImportFailure: Error, LocalizedError {
    case notAFile, tooLarge(Int), incompleteAudio, fileChanged
    var errorDescription: String? {
        switch self {
        case .notAFile: return L10n.text("audio_import.not_file")
        case .tooLarge(let bytes): return L10n.format("audio_import.too_large", bytes / (1024 * 1024))
        case .incompleteAudio: return L10n.text("audio_import.incomplete_audio")
        case .fileChanged: return L10n.text("audio_import.file_changed")
        }
    }
}

/// Besitzt ausschließlich die eigene Arbeitskopie. Der Main-Thread löscht sie
/// erst, wenn prepare()/transcribe() beendet und alle Writer geschlossen sind.
final class AudioFileImportWork {
    let source: URL
    let workingURL: URL
    let limits: AudioImportLimits
    private let makeWriter: (URL) throws -> any DictationWavWriter
    private let beforeChunk: ((Int) async -> Void)?
    private let lock = NSLock()
    private var complete = false
    private var duration: TimeInterval = 0
    private var capturedTexts: [String] = []
    var isComplete: Bool { lock.withLock { complete } }
    var audioDuration: TimeInterval { lock.withLock { duration } }
    var partialTexts: [String] { lock.withLock { capturedTexts } }

    init(source: URL, workingURL: URL, limits: AudioImportLimits,
         makeWriter: @escaping (URL) throws -> any DictationWavWriter,
         beforeChunk: ((Int) async -> Void)?) {
        self.source = source; self.workingURL = workingURL; self.limits = limits
        self.makeWriter = makeWriter; self.beforeChunk = beforeChunk
    }

    func prepare() async throws {
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            guard source.isFileURL,
                  source.resolvingSymlinksInPath().standardizedFileURL != workingURL.resolvingSymlinksInPath().standardizedFileURL else {
                throw AudioImportFailure.notAFile
            }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
            let info = try URL(fileURLWithPath: source.path).resourceValues(forKeys: keys)
            guard info.isRegularFile == true, let size = info.fileSize, size >= 64 else { throw AudioImportFailure.notAFile }
            guard size <= limits.maximumBytes else { throw AudioImportFailure.tooLarge(limits.maximumBytes) }
            let reader = try AudioDecoder.FileReader(url: source, maxSampleCount: limits.maximumSeconds * 16000)
            if let duration = reader.estimatedDuration, duration > Double(limits.maximumSeconds) {
                throw AudioDecoder.DecodeError.tooLong(seconds: limits.maximumSeconds)
            }
            let writer = try makeWriter(workingURL)
            defer { try? writer.finish() }
            var index = 0
            while true {
                await beforeChunk?(index)
                try Task.checkCancellation()
                guard let samples = try reader.read() else { break }
                try writer.append(samples)
                lock.withLock { duration = Double(reader.sampleCount) / 16000 }
                index += 1
            }
            guard reader.sampleCount > 0 else { throw AudioDecoder.DecodeError.empty }
            try writer.finish()
            let after = try URL(fileURLWithPath: source.path).resourceValues(forKeys: keys)
            let changedIdentity: Bool
            if let originalID = info.fileResourceIdentifier as? NSObject, let currentID = after.fileResourceIdentifier as? NSObject {
                changedIdentity = !originalID.isEqual(currentID)
            } else { changedIdentity = false }
            guard info.fileSize == after.fileSize, info.contentModificationDate == after.contentModificationDate, !changedIdentity else {
                throw AudioImportFailure.fileChanged
            }
            lock.withLock { complete = true }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
    }

    func transcribe(request: DictationRequestStore.Snapshot, server: any DictationServer,
                    makeSegmenter: (Config.Vad) -> any DictationSegmenter,
                    timings: DictationTimingStore?, clock: () -> TimeInterval) async throws -> [String?] {
        try Task.checkCancellation()
        let reader: AudioDecoder.FileReader
        do { reader = try AudioDecoder.FileReader(url: workingURL, maxSampleCount: limits.maximumSeconds * 16000) }
        catch {
            if error is AudioDecoder.DecodeError { lock.withLock { complete = false } }
            throw error
        }
        var config = request.config.vad
        config.autoStopAfterSilenceSec = 0
        config.maxSegmentSec = min(30, config.maxSegmentSec)
        config.minSegmentSec = min(config.minSegmentSec, config.maxSegmentSec)
        config.minSpeechSec = min(config.minSpeechSec, config.maxSegmentSec)
        let segmenter = makeSegmenter(config)
        var pending: [VadSegmenter.Segment] = []
        segmenter.onSegment = { if $0.hadSpeech { pending.append($0) } }
        var texts: [String?] = []
        var ready = false
        func drain() async throws -> Bool {
            while !pending.isEmpty {
                try Task.checkCancellation()
                let segment = pending.removeFirst()
                if !ready {
                    try await server.ensureRunning(reachability: request.transcriber)
                    try Task.checkCancellation()
                    request.cleanup.warmUp(); ready = true
                }
                let began = clock()
                defer { timings?.addTranscription(seconds: clock() - began) }
                do {
                    let text = try await request.transcriber.transcribe(samples: segment.samples)
                    try Task.checkCancellation()
                    texts.append(text)
                    lock.withLock { capturedTexts.append(text) }
                } catch {
                    try Task.checkCancellation()
                    texts.append(nil)
                    return false
                }
            }
            return true
        }
        while true {
            let chunk: [Float]?
            do { chunk = try reader.read() }
            catch {
                if error is AudioDecoder.DecodeError { lock.withLock { complete = false } }
                throw error
            }
            guard let samples = chunk else { break }
            segmenter.process(samples)
            if try await drain() == false { return texts }
        }
        segmenter.flush()
        _ = try await drain()
        return texts
    }
}
