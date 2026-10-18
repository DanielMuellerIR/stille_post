import CryptoKit
import XCTest
@testable import StillePostClientCore

final class ModelDownloadTests: XCTestCase {
    private let data = Data("0123456789abcdef".utf8)

    private func file() -> LocalModelFile {
        LocalModelFile(path: "model.bin", size: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://huggingface.co/fixture/model/resolve/\(String(repeating: "a", count: 40))/model.bin")!)
    }

    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("model.bin.part")
    }

    private func downloader(_ handler: @escaping @Sendable (URLRequest) throws -> ModelDownloadStub.Reply) -> HTTPSModelDownloader {
        ModelDownloadStub.setHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadStub.self]
        return HTTPSModelDownloader(configuration: configuration)
    }

    func testHTTPRangeResumesExactRemainingBytes() async throws {
        let target = try destination(), data = data
        try data.prefix(5).write(to: target)
        let transport = downloader { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=5-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            return .init(status: 206, headers: ["Content-Range": "bytes 5-15/16", "Content-Length": "11"], parts: [data.dropFirst(5)])
        }
        try await transport.download(file(), to: target) { _ in }
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testInsecureInitialURLIsRejectedWithoutRequestOrFileCreation() async throws {
        let target = try destination(), original = file()
        let transport = downloader { _ in XCTFail("Keine HTTP-Anfrage zulässig"); throw URLError(.unsupportedURL) }
        let invalid = LocalModelFile(path: original.path, size: original.size, sha256: original.sha256,
            url: URL(string: original.url.absoluteString.replacingOccurrences(of: "https:", with: "http:"))!)
        do { try await transport.download(invalid, to: target) { _ in }; XCTFail("HTTP muss scheitern") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .invalidCatalog) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testIgnoredRangeReplacesOldPartInsteadOfAppending() async throws {
        let target = try destination(), data = data
        try Data("wrong".utf8).write(to: target)
        let transport = downloader { _ in .init(status: 200, headers: ["Content-Length": "16"], parts: [data]) }
        try await transport.download(file(), to: target) { _ in }
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testMismatchedRangeIsRejectedBeforeWriting() async throws {
        let target = try destination(), data = data
        try data.prefix(5).write(to: target)
        let transport = downloader { _ in
            .init(status: 206, headers: ["Content-Range": "bytes 4-15/16", "Content-Length": "12"], parts: [data.dropFirst(4)])
        }
        do { try await transport.download(file(), to: target) { _ in }; XCTFail("Falscher Range muss scheitern") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .invalidResponse) }
        XCTAssertEqual(try Data(contentsOf: target), data.prefix(5))
    }

    func testOverlongChunkedBodyIsBoundedAndTruncatedResponseFails() async throws {
        let target = try destination()
        let transport = downloader { _ in .init(status: 200, headers: [:], parts: [Data(repeating: 0, count: 17)]) }
        do { try await transport.download(file(), to: target) { _ in }; XCTFail("Übergröße muss scheitern") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .integrity) }
        XCTAssertLessThanOrEqual(try Data(contentsOf: target).count, 16)
        let short = downloader { _ in .init(status: 200, headers: [:], parts: [Data("short".utf8)]) }
        do { try await short.download(file(), to: target) { _ in }; XCTFail("Vorzeitiges Ende muss scheitern") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .integrity) }
    }

    func testCancellationClosesPendingSessionWithoutWritingResponseBytes() async throws {
        let target = try destination(), started = expectation(description: "GET ausgelöst")
        let transport = downloader { _ in
            started.fulfill()
            return .init(status: 200, headers: [:], parts: [], holdOpen: true)
        }
        let task = Task { try await transport.download(file(), to: target) { _ in } }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Abbruch erwartet") } catch is CancellationError { }
        XCTAssertTrue(try Data(contentsOf: target).isEmpty)
        let data = data
        let next = downloader { _ in .init(status: 200, headers: ["Content-Length": "16"], parts: [data]) }
        try await next.download(file(), to: target) { _ in }
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
}

private final class ModelDownloadStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let parts: [Data]
        var holdOpen = false
    }
    private static let lock = NSLock()
    private static var handler: (@Sendable (URLRequest) throws -> Reply)?
    static func setHandler(_ action: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.lock(); handler = action; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let action = Self.handler; Self.lock.unlock()
        do {
            guard let action else { throw URLError(.unsupportedURL) }
            let reply = try action(request)
            if reply.holdOpen { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for part in reply.parts { client?.urlProtocol(self, didLoad: part) }
            if !reply.holdOpen { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
