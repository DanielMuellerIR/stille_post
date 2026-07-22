import Foundation

/// Schmale HTTP-Grenze der Textbereinigung. Sie hält Netzwerkdetails aus der
/// Fallback-Logik heraus und erlaubt vollständige Stream-Fehlerpfade ohne echten
/// Ollama-Prozess deterministisch zu testen.
protocol CleanupTransport: AnyObject {
    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse)
    func streamLines(for request: URLRequest, freshConnection: Bool) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse)
    func sendWarmUp(_ request: URLRequest)
}

final class URLSessionCleanupTransport: CleanupTransport {
    private let session: URLSession
    private let probeSession: URLSession
    private let streamSession: URLSession

    init() {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 120
        session = URLSession(configuration: sessionConfig)

        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = 2
        probeConfig.timeoutIntervalForResource = 2
        probeSession = URLSession(configuration: probeConfig)
        streamSession = Self.makeStreamSession()
    }

    static func makeStreamSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Leerlauf-Timeout: Solange Häppchen fließen, darf die Antwort weiterlaufen.
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }

    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        try await (probing ? probeSession : session).data(for: request)
    }

    func streamLines(for request: URLRequest, freshConnection: Bool) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let selectedSession = freshConnection ? Self.makeStreamSession() : streamSession
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await selectedSession.bytes(for: request)
        } catch {
            if freshConnection { selectedSession.invalidateAndCancel() }
            throw error
        }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if freshConnection { selectedSession.finishTasksAndInvalidate() }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
        return (lines, response)
    }

    func sendWarmUp(_ request: URLRequest) {
        session.dataTask(with: request).resume()
    }
}
