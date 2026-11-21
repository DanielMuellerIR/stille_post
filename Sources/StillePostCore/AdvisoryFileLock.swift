import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum AdvisoryFileLock {
    static func withExclusiveAccess<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = try retryInterrupted {
            url.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR)) }
        }
        defer { _ = close(descriptor) }
        _ = try retryInterrupted { flock(descriptor, LOCK_EX) }
        return try body()
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
