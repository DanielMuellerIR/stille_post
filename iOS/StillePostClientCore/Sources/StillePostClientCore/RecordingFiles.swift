import Foundation

public struct Recording: Codable, Equatable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let bytes: Int
    public init(url: URL, duration: TimeInterval, bytes: Int) { self.url = url; self.duration = duration; self.bytes = bytes }
}

@MainActor public protocol RecordingFiles: AnyObject {
    func existing() throws -> Recording?
    func prepare() throws -> URL
    func finish(duration: TimeInterval) throws -> Recording
    func discard() throws
}

@MainActor public final class PendingRecordingFiles: RecordingFiles {
    private let directory: URL
    private var audio: URL { directory.appendingPathComponent("pending.m4a") }
    private var metadata: URL { directory.appendingPathComponent("pending.json") }

    public init(directory: URL) { self.directory = directory }

    public func existing() throws -> Recording? {
        guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: audio.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ClientFailure.storageFailed }
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let duration = (try? JSONDecoder().decode(TimeInterval.self, from: Data(contentsOf: metadata))) ?? 0
        return Recording(url: audio, duration: duration.isFinite ? max(0, duration) : 0, bytes: bytes)
    }

    public func prepare() throws -> URL {
        guard !FileManager.default.fileExists(atPath: audio.path) else { throw ClientFailure.recordingExists }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return audio
    }

    public func finish(duration: TimeInterval) throws -> Recording {
        try JSONEncoder().encode(duration).write(to: metadata, options: .atomic)
        guard let recording = try existing(), recording.bytes > 0 else { throw ClientFailure.noAudio }
        return recording
    }

    public func discard() throws {
        // Ausschließlich eigene feste Dateien; niemals einen vom Server gelieferten Pfad löschen.
        if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
    }
}
