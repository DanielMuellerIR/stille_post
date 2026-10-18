import Foundation

public struct AudioImportLimits: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumSeconds: Int
    public static let shortClip = Self(maximumBytes: 50 * 1024 * 1024, maximumSeconds: 300)
    public static let file = Self(maximumBytes: 250 * 1024 * 1024, maximumSeconds: 1800)
}

public enum AudioImportStage: Equatable, Sendable { case decoding, transcribing, cleaning }

public struct AudioImportProgress: Equatable, Sendable {
    public let stage: AudioImportStage
    public let audioSeconds: TimeInterval
    public let totalSeconds: TimeInterval?
    public let completedSegments: Int
    public let stageComplete: Bool
    public var fraction: Double? {
        guard let totalSeconds, totalSeconds > 0 else { return nil }
        return stageComplete ? 1 : min(0.99, max(0, audioSeconds / totalSeconds))
    }
}

enum AudioImportFailure: Error, LocalizedError {
    case notAFile, tooLarge(Int), incompleteAudio, fileChanged, transcriptionFailed(Int), alreadyCompleted
    var errorDescription: String? {
        switch self {
        case .notAFile: return L10n.text("audio_import.not_file")
        case .tooLarge(let bytes): return L10n.format("audio_import.too_large", bytes / (1024 * 1024))
        case .incompleteAudio: return L10n.text("audio_import.incomplete_audio")
        case .fileChanged: return L10n.text("audio_import.file_changed")
        case .transcriptionFailed(let count): return L10n.format("core.dictation.segments_failed", count)
        case .alreadyCompleted: return L10n.text("audio_import.already_completed")
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
    private let onProgress: ((AudioImportProgress) -> Void)?
    private var lastProgressTime: TimeInterval = 0
    private let lock = NSLock()
    private var complete = false
    private var duration: TimeInterval = 0
    private var capturedTexts: [String] = []
    var isComplete: Bool { lock.withLock { complete } }
    var audioDuration: TimeInterval { lock.withLock { duration } }
    var partialTexts: [String] { lock.withLock { capturedTexts } }

    init(source: URL, workingURL: URL, limits: AudioImportLimits,
         makeWriter: @escaping (URL) throws -> any DictationWavWriter,
         beforeChunk: ((Int) async -> Void)?, onProgress: ((AudioImportProgress) -> Void)? = nil) {
        self.source = source; self.workingURL = workingURL; self.limits = limits
        self.makeWriter = makeWriter; self.beforeChunk = beforeChunk
        self.onProgress = onProgress
    }

    func prepare() async throws {
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            guard source.isFileURL,
                  source.path.hasPrefix("/"), source.host == nil || source.host == "" || source.host?.lowercased() == "localhost",
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
            report(.decoding, seconds: 0, total: reader.estimatedDuration, force: true)
            var index = 0
            while true {
                await beforeChunk?(index)
                try Task.checkCancellation()
                guard let samples = try reader.read() else { break }
                try writer.append(samples)
                lock.withLock { duration = Double(reader.sampleCount) / 16000 }
                report(.decoding, seconds: audioDuration, total: reader.estimatedDuration)
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
            report(.decoding, seconds: audioDuration, total: audioDuration, complete: true, force: true)
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
    }

    /// Eine erhaltene Import-WAV ist bereits normalisiert. Sie wird beim Retry
    /// gelesen, nicht erneut kopiert; die Verlaufssicherung besitzt ihre Löschung.
    func prepareRetainedAudio() throws {
        let info = try URL(fileURLWithPath: workingURL.path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size >= 64 else { throw AudioImportFailure.notAFile }
        guard size <= limits.maximumBytes else { throw AudioImportFailure.tooLarge(limits.maximumBytes) }
        let reader = try AudioDecoder.FileReader(url: workingURL, maxSampleCount: limits.maximumSeconds * 16000)
        guard let seconds = reader.estimatedDuration, seconds > 0 else { throw AudioDecoder.DecodeError.empty }
        guard seconds <= Double(limits.maximumSeconds) else { throw AudioDecoder.DecodeError.tooLong(seconds: limits.maximumSeconds) }
        lock.withLock { duration = seconds; complete = true }
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
        var config = request.config.vad.runtimeSafe
        config.autoStopAfterSilenceSec = 0
        config.maxSegmentSec = min(30, config.maxSegmentSec)
        config.minSegmentSec = min(config.minSegmentSec, config.maxSegmentSec)
        config.minSpeechSec = min(config.minSpeechSec, config.maxSegmentSec)
        // Ein Vorlauf über der Segmentgrenze würde nach jedem Schnitt weiter
        // anwachsen und die Begrenzung der Audioanfragen aushebeln.
        config.paddingSec = min(config.paddingSec, min(1, config.maxSegmentSec / 2))
        let segmenter = makeSegmenter(config)
        var pending: [VadSegmenter.Segment] = []
        segmenter.onSegment = { if $0.hadSpeech { pending.append($0) } }
        var texts: [String?] = []
        var ready = false
        report(.transcribing, seconds: 0, total: audioDuration, force: true)
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
            // Erst nach dem Await ist das gelesene Audio tatsächlich abgearbeitet.
            report(.transcribing, seconds: Double(reader.sampleCount) / 16000,
                   total: audioDuration, segments: texts.count)
        }
        segmenter.flush()
        _ = try await drain()
        report(.transcribing, seconds: audioDuration, total: audioDuration,
               segments: texts.count, complete: !texts.contains(where: { $0 == nil }), force: true)
        return texts
    }

    private func report(_ stage: AudioImportStage, seconds: TimeInterval, total: TimeInterval?,
                        segments: Int = 0, complete: Bool = false, force: Bool = false) {
        guard let onProgress else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now
        onProgress(.init(stage: stage, audioSeconds: seconds, totalSeconds: total,
                         completedSegments: segments, stageComplete: complete))
    }
}
