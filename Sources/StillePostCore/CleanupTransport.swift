import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CFNetwork)
import CFNetwork
#endif

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
    private let localOnly: Bool
    private let redirectGuard: CleanupRedirectGuard
    private let session: URLSession
    private let probeSession: URLSession
    private let streamSession: URLSession

    init(localOnly: Bool = false) {
        self.localOnly = localOnly
        redirectGuard = CleanupRedirectGuard(localOnly: localOnly)
#if os(Linux)
        LinuxNetworkBootstrap.prepare()
#endif
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 120
        Self.configure(sessionConfig, localOnly: localOnly)
        session = URLSession(configuration: sessionConfig, delegate: redirectGuard, delegateQueue: nil)

        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = 2
        probeConfig.timeoutIntervalForResource = 2
        Self.configure(probeConfig, localOnly: localOnly)
        probeSession = URLSession(configuration: probeConfig, delegate: redirectGuard, delegateQueue: nil)
        streamSession = Self.makeStreamSession(localOnly: localOnly)
    }

    deinit {
        session.invalidateAndCancel()
        probeSession.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    static func makeStreamSession(localOnly: Bool = false) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Leerlauf-Timeout: Solange Häppchen fließen, darf die Antwort weiterlaufen.
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 600
        configure(config, localOnly: localOnly)
        return URLSession(configuration: config, delegate: CleanupRedirectGuard(localOnly: localOnly), delegateQueue: nil)
    }

    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        try check(request)
        return try await (probing ? probeSession : session).data(for: request)
    }

    func streamLines(for request: URLRequest, freshConnection: Bool) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        try check(request)
#if os(Linux)
        return try await LinuxLineStream.open(request)
#else
        let selectedSession = freshConnection ? Self.makeStreamSession(localOnly: localOnly) : streamSession
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
#endif
    }

    private func check(_ request: URLRequest) throws {
        if localOnly && !CleanupNetworkPolicy.allows(request.url) { throw CleanupNetworkPolicy.Denied() }
    }

    private static func configure(_ config: URLSessionConfiguration, localOnly: Bool) {
        guard localOnly else { return }
        // Auch ein Systemproxy/PAC darf lokale Diktate nicht ausleiten.
#if canImport(CFNetwork)
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0, kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0,
        ]
#else
        config.connectionProxyDictionary = [:]
#endif
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
    }

    func sendWarmUp(_ request: URLRequest) {
        guard (try? check(request)) != nil else { return }
        session.dataTask(with: request).resume()
    }
}

private final class CleanupRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let localOnly: Bool
    init(localOnly: Bool) { self.localOnly = localOnly }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(!localOnly || CleanupNetworkPolicy.allows(request.url) ? request : nil)
    }
}
