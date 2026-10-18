import Foundation
import Security
import CryptoKit

public struct LocalHTTPTransport: BridgeTransport {
    public init() {}
    public func perform(_ request: URLRequest, file: URL?, fingerprint: String?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPReply {
        guard request.url?.scheme?.lowercased() == "https", let fingerprint, BridgeConfiguration.validFingerprint(fingerprint) else { throw ClientFailure.pairingRequired }
        let transfer = Transfer(fingerprint: fingerprint, progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { transfer.start(request, file: file, continuation: $0) }
        } onCancel: { transfer.cancel() }
    }
}

// Lock schützt Start/Storno; URLSession liefert ihre Delegatenaufrufe seriell.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPReply, Error>?
    private var session: URLSession?
    private var task: URLSessionTask?
    private var cancelled = false
    private var body = Data()
    private var status = 0
    private var failure: ClientFailure?
    private let fingerprint: String
    private let progress: @Sendable (Double) -> Void

    init(fingerprint: String, progress: @escaping @Sendable (Double) -> Void) { self.fingerprint = fingerprint; self.progress = progress }

    func start(_ request: URLRequest, file: URL?, continuation: CheckedContinuation<HTTPReply, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.allowsCellularAccess = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 240
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = file.map { session.uploadTask(with: request, fromFile: $0) } ?? session.dataTask(with: request)
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        do {
            try PinnedTrust.validate(trust, fingerprint: fingerprint)
            completionHandler(.useCredential, URLCredential(trust: trust))
        } catch {
            failure = error as? ClientFailure ?? .invalidCertificate
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Auch ein lokaler Server darf Audio und Bearer-Token nicht weiterleiten.
        failure = .redirected
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            failure = .invalidResponse; completionHandler(.cancel); return
        }
        status = response.statusCode
        guard response.expectedContentLength <= BridgeClient.maxResponseBytes else {
            failure = .responseTooLarge; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= BridgeClient.maxResponseBytes - body.count else {
            failure = .responseTooLarge; dataTask.cancel(); return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil; self.task = nil; self.session = nil
        let wasCancelled = cancelled
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: HTTPReply(status: status, body: body)) }
    }
}
