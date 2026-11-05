#if os(Linux)
import Foundation
import FoundationNetworking
import LinuxNative

public enum SileroModel {
    public static let revision = "7e30209a3e901f9842f81b225f3e93d8199902b1"
    public static let name = "silero-vad-v6.2.1.onnx"
    static let bytes = 2_327_524
    static let sha256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
    public static var directory: URL {
        Config.appSupportDir.appendingPathComponent("models/silero-\(revision)")
    }
    public enum Failure: Error, LocalizedError {
        case missing, integrity, unavailable, download
        public var errorDescription: String? {
            switch self {
            case .missing: return L10n.text("vad.fallback.missing")
            case .integrity: return L10n.text("vad.fallback.integrity")
            case .unavailable: return L10n.text("vad.fallback.linux_runtime")
            case .download: return L10n.text("vad.download_failed")
            }
        }
    }
    static func verify(_ data: Data) throws {
        var digest = [UInt8](repeating: 0, count: 32)
        guard data.count == bytes,
            data.withUnsafeBytes({
                sp_sha256($0.bindMemory(to: UInt8.self).baseAddress, data.count, &digest)
            }) == 1,
            digest.map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw Failure.integrity }
    }
    static func validate(at folder: URL) throws {
        let file = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.missing }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.intValue == bytes
        else { throw Failure.integrity }
        try verify(Data(contentsOf: file))
    }
    public static func availability() async -> String? {
        await Task.detached {
            do {
                try validate(at: directory)
                return nil
            } catch { return error.localizedDescription }
        }.value
    }
    public static func install() async throws { try await installer.install() }
    private static let installer = Installer()
    private actor Installer {
        private var busy = false
        func install() async throws {
            guard !busy else { throw Failure.download }
            busy = true
            defer { busy = false }
            if (try? SileroModel.validate(at: SileroModel.directory)) != nil { return }
            let url = URL(
                string:
                    "https://raw.githubusercontent.com/snakers4/silero-vad/\(SileroModel.revision)/src/silero_vad/data/silero_vad.onnx"
            )!
            let data = try await LinuxModelDownload.fetch(url, maximum: SileroModel.bytes)
            try Task.checkCancellation()
            try SileroModel.verify(data)
            let manager = FileManager.default
            let folder = SileroModel.directory
            try manager.createDirectory(
                at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = folder.deletingLastPathComponent().appendingPathComponent(
                ".silero-\(UUID().uuidString)")
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: staging) }
            try data.write(to: staging.appendingPathComponent(SileroModel.name), options: .atomic)
            try SileroModel.validate(at: staging)
            try Task.checkCancellation()
            if manager.fileExists(atPath: folder.path) {
                if (try? SileroModel.validate(at: folder)) != nil { return }
                try manager.moveItem(
                    at: folder,
                    to: folder.deletingLastPathComponent().appendingPathComponent(
                        ".silero-invalid-\(UUID().uuidString)"))
            }
            try manager.moveItem(at: staging, to: folder)
        }
    }
}

final class SileroSpeechDetector: SpeechActivityDetector {
    let frameSize = 4096
    private let context: OpaquePointer
    init(directory: URL) throws {
        try SileroModel.validate(at: directory)
        guard
            let context = directory.appendingPathComponent(SileroModel.name).path.withCString({
                sp_silero_new($0)
            })
        else { throw SileroModel.Failure.unavailable }
        self.context = context
    }
    deinit { sp_silero_free(context) }
    func probability(_ samples: [Float]) throws -> Float {
        guard !samples.isEmpty, samples.count <= frameSize, samples.allSatisfy({ $0.isFinite })
        else {
            throw SileroModel.Failure.unavailable
        }
        var padded = samples
        if padded.count < frameSize {
            padded += [Float](repeating: 0, count: frameSize - padded.count)
        }
        var value: Float = 0
        guard
            padded.withUnsafeBufferPointer({
                sp_silero_probability(context, $0.baseAddress, &value)
            })
                == 1, value.isFinite, (0...1).contains(value)
        else { throw SileroModel.Failure.unavailable }
        return value
    }
    func isSpeech(_ samples: [Float]) throws -> Bool { try probability(samples) >= 0.85 }
}
extension VadSegmenter {
    public static func prepared(config: Config.Vad, modelDirectory: URL = SileroModel.directory)
        async -> VadSegmenter
    {
        guard config.detector == .silero else { return VadSegmenter(config: config) }
        return await Task.detached {
            do {
                return VadSegmenter(
                    config: config, detector: try SileroSpeechDetector(directory: modelDirectory))
            } catch {
                return VadSegmenter(
                    config: config, detector: nil, fallbackReason: error.localizedDescription)
            }
        }.value
    }
}

/// Der feste kleine Modellabruf benötigt auch ohne Foundation.AsyncBytes eine
/// harte Grenze während des Empfangs; Größenprüfung erst danach reicht nicht.
private final class LinuxModelDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock(), maximum: Int
    private var session: URLSession?, task: URLSessionDataTask?
    private var waiter: CheckedContinuation<Data, Error>?
    private var data = Data(), ended = false, cancelled = false
    init(maximum: Int) { self.maximum = maximum }
    static func fetch(_ url: URL, maximum: Int) async throws -> Data {
        let download = LinuxModelDownload(maximum: maximum)
        return try await withTaskCancellationHandler(
            operation: { try await withCheckedThrowingContinuation { download.start(url, $0) } },
            onCancel: { download.cancel() })
    }
    private func start(_ url: URL, _ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        waiter = continuation
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 30
        options.timeoutIntervalForResource = 120
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: options, delegate: self, delegateQueue: queue)
        self.session = session
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return
        }
        ended = true
        let continuation = waiter
        let session = self.session
        waiter = nil
        self.session = nil
        task = nil
        data.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            response.expectedContentLength <= Int64(maximum)
        else {
            completionHandler(.cancel)
            finish(.failure(SileroModel.Failure.download))
            return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        let fits = chunk.count <= maximum - data.count
        if fits { data.append(chunk) }
        lock.unlock()
        if !fits { finish(.failure(SileroModel.Failure.integrity)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        lock.lock()
        let result = data
        lock.unlock()
        finish(error.map { .failure($0) } ?? .success(result))
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(SileroModel.Failure.download))
    }
}
#endif
