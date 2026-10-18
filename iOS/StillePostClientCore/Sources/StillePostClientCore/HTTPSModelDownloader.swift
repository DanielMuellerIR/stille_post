import Foundation

public struct HTTPSModelDownloader: LocalModelDownloading, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    public func download(_ file: LocalModelFile, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        let operation = ModelDownloadOperation(file: file, destination: destination, progress: progress)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await operation.run(configuration: configuration)
        } onCancel: { operation.cancel() }
    }
}

private final class ModelDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: LocalModelFile
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    // Empfang und Dateioperationen laufen ausschließlich auf der seriellen Delegate-Queue.
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: LocalModelFailure?
    private var accepted = false
    private var lastProgress = Date.distantPast

    init(file: LocalModelFile, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file; self.destination = destination; self.progress = progress
    }

    func run(configuration: URLSessionConfiguration) async throws {
        guard LocalModelCatalog.isPinnedSource(file.url), file.size > 0 else { throw LocalModelFailure.invalidCatalog }
        defer { try? handle?.close() }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LocalModelFailure.storage }
            received = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } else {
            guard manager.createFile(atPath: destination.path, contents: nil) else { throw LocalModelFailure.storage }
        }
        guard received >= 0, received < file.size else { throw LocalModelFailure.integrity }
        handle = try FileHandle(forWritingTo: destination)
        try handle?.seekToEnd()
        var request = URLRequest(url: file.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.connectionProxyDictionary = [:]
        config.timeoutIntervalForResource = 1800; config.httpMaximumConnectionsPerHost = 1
        config.allowsCellularAccess = false; config.allowsExpensiveNetworkAccess = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let connection = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session = connection
        try await withCheckedThrowingContinuation { waiting in
            let download = connection.dataTask(with: request)
            lock.lock()
            continuation = waiting; task = download
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { download.cancel() }
            download.resume()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host,
              host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co") else {
            failure = .invalidResponse; completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206,
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            failure = .invalidResponse; completionHandler(.cancel); return
        }
        if http.statusCode == 206 {
            let expected = "bytes \(received)-\(file.size - 1)/\(file.size)"
            guard http.value(forHTTPHeaderField: "Content-Range") == expected else {
                failure = .invalidResponse; completionHandler(.cancel); return
            }
        } else if received > 0 {
            // Manche CDNs ignorieren Range. Die neue Vollantwort darf keine alten Bytes anhängen.
            do { try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0); received = 0 }
            catch { failure = .storage; completionHandler(.cancel); return }
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength == file.size - received else {
            failure = .invalidResponse; completionHandler(.cancel); return
        }
        accepted = true; progress(received); completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, failure == nil else { dataTask.cancel(); return }
        guard Int64(data.count) <= file.size - received else {
            failure = .integrity; dataTask.cancel(); return
        }
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            let now = Date()
            if received == file.size || now.timeIntervalSince(lastProgress) >= 0.1 {
                lastProgress = now; progress(received)
            }
        } catch { failure = .storage; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close(); handle = nil
        lock.lock()
        let waiting = continuation; continuation = nil; self.task = nil
        let wasCancelled = cancelled
        lock.unlock()
        session.invalidateAndCancel(); self.session = nil
        if wasCancelled { waiting?.resume(throwing: CancellationError()) }
        else if let failure { waiting?.resume(throwing: failure) }
        else if error != nil { waiting?.resume(throwing: LocalModelFailure.download) }
        else if !accepted || received != file.size { waiting?.resume(throwing: LocalModelFailure.integrity) }
        else { waiting?.resume() }
    }
}
