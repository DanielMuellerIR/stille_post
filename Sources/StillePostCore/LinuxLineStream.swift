#if os(Linux)
import Foundation
import FoundationNetworking

/// FoundationNetworking besitzt noch kein URLSession.AsyncBytes. Der Delegate
/// liefert Zeilen sofort und begrenzt sowohl Frames als auch die Gesamtantwort.
final class LinuxLineStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var responseWaiter: CheckedContinuation<URLResponse, Error>?
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var pending = Data()
    private var total = 0
    private let lock = NSLock()
    private var ended = false
    private var cancellationRequested = false

    static func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let delegate = LinuxLineStream()
        let lines = AsyncThrowingStream<String, Error> { delegate.continuation = $0 }
        delegate.continuation?.onTermination = { @Sendable _ in delegate.cancel() }
        let response = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<URLResponse, Error>) in
                delegate.lock.lock()
                if delegate.cancellationRequested {
                    delegate.lock.unlock(); waiter.resume(throwing: CancellationError()); return
                }
                delegate.responseWaiter = waiter
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 10
                config.timeoutIntervalForResource = 600
                config.connectionProxyDictionary = [:]
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                delegate.session = session
                delegate.task = session.dataTask(with: request)
                delegate.task?.resume()
                delegate.lock.unlock()
            }
        }, onCancel: { delegate.cancel() })
        return (lines, response)
    }
    private func cancel() {
        lock.lock(); cancellationRequested = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); let waiter = responseWaiter; responseWaiter = nil; lock.unlock()
        waiter?.resume(returning: response)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        total += data.count
        pending.append(data)
        guard total <= 16 * 1024 * 1024, pending.count <= 1024 * 1024 else {
            finish(LinuxFailure.protocolFailure); dataTask.cancel(); return
        }
        while let newline = pending.firstIndex(of: 10) {
            let bytes = pending.prefix(upTo: newline)
            guard let text = String(data: bytes, encoding: .utf8) else {
                finish(LinuxFailure.protocolFailure); dataTask.cancel(); return
            }
            continuation?.yield(text.hasSuffix("\r") ? String(text.dropLast()) : text)
            pending.removeSubrange(...newline)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, !pending.isEmpty {
            if let line = String(data: pending, encoding: .utf8) { continuation?.yield(line) }
            else { finish(LinuxFailure.protocolFailure); return }
        }
        finish(error)
    }
    private func finish(_ error: Error?) {
        guard !ended else { return }; ended = true
        lock.lock(); let waiter = responseWaiter; responseWaiter = nil; lock.unlock()
        waiter?.resume(throwing: error ?? LinuxFailure.protocolFailure)
        continuation?.finish(throwing: error)
        continuation = nil
        session?.invalidateAndCancel(); session = nil; task = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Auch Text-Streams wechseln nicht stillschweigend den konfigurierten Dienst.
        completionHandler(nil)
    }
}
#endif
