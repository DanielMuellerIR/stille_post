import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AdvisoryFileLock {
    static func withExclusiveAccess<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = try acquire(at: url)
        defer { _ = close(descriptor) }
        return try body()
    }

    /// Der Aufrufer hält den Lock bis zum Schließen des Deskriptors.
    static func acquire(at url: URL, nonBlocking: Bool = false) throws -> Int32 {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = try retryInterrupted {
            url.path.withCString {
                open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(S_IRUSR | S_IWUSR))
            }
        }
        do {
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG else {
                throw POSIXError(.EINVAL)
            }
            _ = try retryInterrupted { flock(descriptor, nonBlocking ? LOCK_EX | LOCK_NB : LOCK_EX) }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func retryInterrupted(_ operation: () -> Int32) throws -> Int32 {
        while true {
            let result = operation()
            if result >= 0 { return result }
            let error = errno
            guard error == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        }
    }
}
