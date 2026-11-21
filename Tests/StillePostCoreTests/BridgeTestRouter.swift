import XCTest
@testable import StillePostCore

/// Zähler, mit dem die Tests belegen, wie oft die Bereinigung wirklich lief.
final class BridgeCleanupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

func makeBridgeRouter(
    token: String? = "richtig",
    cleanupEnabled: Bool = true,
    transcribe: @escaping @Sendable (Data) async throws -> String = { _ in "roher text" },
    cleanupCounter: BridgeCleanupCounter? = nil,
    maxBodyBytes: Int = 1024
) -> BridgeRouter {
    let handlers = BridgeHandlers(
        transcribe: transcribe,
        cleanup: { raw in
            cleanupCounter?.increment()
            return CleanupService.Result(text: "Sauberer Text.", usedFallback: false,
                                         fallbackReason: nil, endpoint: "test")
        },
        cleanupEnabled: cleanupEnabled,
        version: "test"
    )
    return BridgeRouter(handlers: handlers, maxBodyBytes: maxBodyBytes,
                        tokenProvider: { token })
}
