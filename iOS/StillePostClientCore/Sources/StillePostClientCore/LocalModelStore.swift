import CryptoKit
import Foundation

public struct LocalModelInventory: Equatable, Sendable {
    public let installed: Bool
    public let downloadedBytes: Int64
    public let totalBytes: Int64
    public var hasFiles: Bool { installed || downloadedBytes > 0 }
}

public protocol LocalModelDownloading: Sendable {
    func download(_ file: LocalModelFile, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

public actor LocalModelStore {
    public let catalog: LocalModelCatalog
    private let directory: URL
    private var active = false
    private let capacity: @Sendable (URL) throws -> Int64
    private var installed: URL { directory.appendingPathComponent("Installed", isDirectory: true) }
    private var partial: URL { directory.appendingPathComponent("Download", isDirectory: true) }

    public init(directory: URL, catalog: LocalModelCatalog,
                capacity: @escaping @Sendable (URL) throws -> Int64 = { try LocalModelStore.availableCapacity($0) }) throws {
        try catalog.validate()
        self.directory = directory; self.catalog = catalog; self.capacity = capacity
    }

    public static func availableCapacity(_ directory: URL) throws -> Int64 {
        guard let bytes = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { throw LocalModelFailure.storage }
        return bytes
    }

    public func inventory() throws -> LocalModelInventory {
        try prepareDirectory()
        try Self.safePath(installed, beneath: directory)
        try Self.safePath(partial, beneath: directory)
        let exists = FileManager.default.fileExists(atPath: installed.path)
        var bytes: Int64 = 0
        let root = exists ? installed : partial
        for file in catalog.files {
            let url = root.appendingPathComponent(file.path)
            if let count = try? Self.regularFileSize(url, beneath: directory) { bytes += min(count, file.size) }
            if !exists, let count = try? Self.regularFileSize(partURL(file), beneath: directory) { bytes += min(count, file.size) }
        }
        return LocalModelInventory(installed: exists, downloadedBytes: min(bytes, catalog.totalBytes), totalBytes: catalog.totalBytes)
    }

    public func validateInstalled() throws -> URL {
        guard !active else { throw LocalModelFailure.busy }
        try prepareDirectory()
        try Self.safePath(installed, beneath: directory)
        guard FileManager.default.fileExists(atPath: installed.path) else { throw LocalModelFailure.missing }
        for file in catalog.files {
            try Self.verify(installed.appendingPathComponent(file.path), file: file, beneath: directory)
        }
        guard try capacity(directory) >= LocalModelCatalog.workingReserveBytes else { throw LocalModelFailure.insufficientSpace }
        return installed
    }

    public func install(using downloader: any LocalModelDownloading = HTTPSModelDownloader(),
                        progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard !active else { throw LocalModelFailure.busy }
        active = true; defer { active = false }
        try prepareDirectory()
        try Self.safePath(installed, beneath: directory)
        try Self.safePath(partial, beneath: directory)
        guard !FileManager.default.fileExists(atPath: installed.path) else { throw LocalModelFailure.alreadyInstalled }
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        var completed: Int64 = 0
        for file in catalog.files {
            try Task.checkCancellation()
            let target = partial.appendingPathComponent(file.path)
            try Self.safePath(target, beneath: directory)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try Self.regularFileSize(target, beneath: directory)
                var verified = false
                do {
                    try Self.verify(target, file: file, beneath: directory)
                    verified = true
                } catch is CancellationError { throw CancellationError() }
                catch let error as LocalModelFailure where error == .integrity { try FileManager.default.removeItem(at: target) }
                if verified {
                    let obsolete = partURL(file)
                    try Self.safePath(obsolete, beneath: directory)
                    if FileManager.default.fileExists(atPath: obsolete.path) {
                        _ = try Self.regularFileSize(obsolete, beneath: directory)
                        try FileManager.default.removeItem(at: obsolete)
                    }
                    completed += file.size; progress(completed); continue
                }
            }
            let temporary = partURL(file)
            try Self.safePath(temporary, beneath: directory)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let count = FileManager.default.fileExists(atPath: temporary.path)
                ? try Self.regularFileSize(temporary, beneath: directory) : 0
            guard count <= file.size else { try FileManager.default.removeItem(at: temporary); throw LocalModelFailure.integrity }
            let remaining = catalog.totalBytes - completed - count
            guard try capacity(directory) >= remaining + LocalModelCatalog.workingReserveBytes else { throw LocalModelFailure.insufficientSpace }
            let previous = completed
            if count < file.size {
                try await downloader.download(file, to: temporary) { progress(previous + $0) }
            }
            do { try Self.verify(temporary, file: file, beneath: directory) }
            catch is CancellationError { throw CancellationError() }
            catch {
                if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
                throw LocalModelFailure.integrity
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: target)
            completed += file.size; progress(completed)
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: partial, to: installed)
    }

    public func remove() throws {
        guard !active else { throw LocalModelFailure.busy }
        try prepareDirectory()
        for own in [installed, partial] where FileManager.default.fileExists(atPath: own.path) {
            try Self.safePath(own, beneath: directory)
            try FileManager.default.removeItem(at: own)
        }
    }

    private func partURL(_ file: LocalModelFile) -> URL {
        partial.appendingPathComponent(file.path + ".part")
    }

    private func prepareDirectory() throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw LocalModelFailure.storage }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw LocalModelFailure.storage }
        var root = directory
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try root.setResourceValues(attributes)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
    }

    private static func regularFileSize(_ url: URL, beneath root: URL) throws -> Int64 {
        try safePath(url, beneath: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw LocalModelFailure.storage }
        return size.int64Value
    }

    private static func safePath(_ url: URL, beneath root: URL) throws {
        guard url.path.hasPrefix(root.path + "/") else { throw LocalModelFailure.storage }
        var current = root
        for component in url.path.dropFirst(root.path.count + 1).split(separator: "/") {
            current.appendPathComponent(String(component))
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
                let type = attributes[.type] as? FileAttributeType
                guard type != .typeSymbolicLink,
                      current.path == url.path || type == .typeDirectory else { throw LocalModelFailure.storage }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        }
    }

    private static func verify(_ url: URL, file: LocalModelFile, beneath root: URL) throws {
        guard try regularFileSize(url, beneath: root) == file.size else { throw LocalModelFailure.integrity }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            throw LocalModelFailure.integrity
        }
    }
}
