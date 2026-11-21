import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import StillePostCore

final class CleanupResponseTests: XCTestCase {
    func testThinkingTagsDoNotExposeUnfinishedOrUnwrappedReasoning() {
        XCTAssertEqual(CleanupService.stripThinking("<think>Unfertige Überlegung"), "")
        XCTAssertEqual(CleanupService.stripThinking("Fertiger Text.<think>Unfertige Überlegung"), "Fertiger Text.")
        XCTAssertEqual(CleanupService.stripThinking("Überlegung</think>Fertiger Text."), "Fertiger Text.")
        XCTAssertEqual(CleanupService.stripThinking("<think>A<think>B</think>C</think>Fertiger Text."), "Fertiger Text.")
        XCTAssertEqual(CleanupService.stripThinking("Vorher<think>A</think> nachher<think>B</think>."), "Vorher nachher.")
    }

    func testOllamaStreamRejectsNumericCompletion() {
        XCTAssertThrowsError(try CleanupService.streamChunk(fromLine: #"{"done":1}"#)) { error in
            guard case CleanupService.CleanupError.invalidStreamFrame = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
    }

    func testPinnedWarmUpSkipsFinitePrimaryAndAcceptsOtherNegativeDurations() async throws {
        var config = Config.Cleanup()
        config.keepAlive = "30m"
        var pinned = Config.Cleanup.Endpoint()
        pinned.ollamaURL = "http://127.0.0.1:11435"
        pinned.keepAlive = "-2"
        pinned.numCtx = 8192
        config.fallbacks = [pinned]
        let warmed = expectation(description: "Gepinntes Modell vorwärmen")
        let transport = RequestRecordingCleanupTransport(warmed: warmed)

        CleanupService(config: config, transport: transport).warmUp(pinnedOnly: true)
        await fulfillment(of: [warmed], timeout: 2)

        let requests = transport.requests.snapshot
        XCTAssertEqual(requests.map { $0.url?.port }, [11435, 11435])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/version", "/api/generate"])
        let body = try jsonBody(XCTUnwrap(requests.last))
        XCTAssertEqual(body["keep_alive"] as? Int, -2)
        XCTAssertEqual((body["options"] as? [String: Int])?["num_ctx"], 8192)
    }

    func testWarmUpAndStreamShareContextAndRemoveThinkingAcrossFrames() async throws {
        var config = Config.Cleanup()
        config.keepAlive = "2h"
        config.numCtx = 8192
        let warmed = expectation(description: "Primäres Modell vorwärmen")
        let transport = RequestRecordingCleanupTransport(warmed: warmed, frames: [
            #"{"message":{"content":"<th"},"done":false}"#,
            #"{"message":{"content":"ink>Überlegung</thi"},"done":false}"#,
            #"{"message":{"content":"nk>Fertiger Text."},"done":false}"#,
            #"{"done":true}"#,
        ])
        let service = CleanupService(config: config, transport: transport)
        service.warmUp()
        await fulfillment(of: [warmed], timeout: 2)

        let result = await service.clean("ähm fertiger text")

        XCTAssertEqual(result.text, "Fertiger Text.")
        XCTAssertFalse(result.usedFallback)
        let requests = transport.requests.snapshot
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/version", "/api/generate", "/api/chat"])
        let warm = try jsonBody(XCTUnwrap(requests.dropFirst().first))
        let chat = try jsonBody(XCTUnwrap(requests.last))
        let warmOptions = try XCTUnwrap(warm["options"] as? [String: Any])
        let chatOptions = try XCTUnwrap(chat["options"] as? [String: Any])
        XCTAssertEqual(warmOptions["num_ctx"] as? Int, 8192)
        XCTAssertEqual(chatOptions["num_ctx"] as? Int, 8192)
        XCTAssertEqual(warm["keep_alive"] as? String, "2h")
        XCTAssertEqual(chat["keep_alive"] as? String, "2h")
        XCTAssertEqual(warm["model"] as? String, chat["model"] as? String)
        XCTAssertEqual(chat["think"] as? Bool, false)
        XCTAssertEqual(chat["stream"] as? Bool, true)
    }

    func testColdOllamaRetriesPartialTimeoutWithFreshStreamAndNoProbe() async throws {
        let transport = RequestRecordingCleanupTransport(
            frames: [#"{"message":{"content":"Erster"},"done":false}"#],
            streamFailure: URLError(.timedOut),
            retryFrames: [#"{"message":{"content":"Fertiger Text."},"done":true}"#]
        )
        let service = CleanupService(config: Config.Cleanup(), transport: transport)

        let result = await service.clean("ähm fertiger text")

        XCTAssertEqual(result.text, "Fertiger Text.")
        XCTAssertFalse(result.usedFallback)
        let requests = transport.requests.snapshot
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/chat", "/api/chat"])
        XCTAssertEqual(transport.streamFreshness.snapshot, [false, true])
        let body = try jsonBody(XCTUnwrap(requests.first))
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testEachProviderPathKeepsLiteralTagsAndRemovesReasoning() async throws {
        for path in ProviderPath.allCases {
            let literal = "Lass <think> und </think> im Text."
            let unchanged = try await clean(literal, modelText: literal, via: path)
            XCTAssertEqual(unchanged.text, literal, "\(path)")
            XCTAssertFalse(unchanged.usedFallback, "\(path)")

            let raw = "ähm fertiger text"
            let cleaned = try await clean(raw, modelText: "Überlegung</think>Fertiger Text.", via: path)
            XCTAssertEqual(cleaned.text, "Fertiger Text.", "\(path)")
            XCTAssertFalse(cleaned.usedFallback, "\(path)")

            let ambiguous = try await clean(literal, modelText: "<think>Überlegung</think>\(literal)", via: path)
            XCTAssertEqual(ambiguous.text, literal, "\(path)")
            XCTAssertTrue(ambiguous.usedFallback, "\(path)")
        }
    }

    private enum ProviderPath: CaseIterable {
        case ollamaStream
        case ollamaComplete
        case openAIComplete
    }

    private func clean(_ raw: String, modelText: String, via path: ProviderPath) async throws -> CleanupService.Result {
        var config = Config.Cleanup()
        config.localOnly = true
        let message = ["content": modelText]
        let transport: RequestRecordingCleanupTransport
        switch path {
        case .ollamaStream:
            let frame = try JSONSerialization.data(withJSONObject: ["message": message, "done": true])
            transport = RequestRecordingCleanupTransport(frames: [String(decoding: frame, as: UTF8.self)])
        case .ollamaComplete:
            let body = try JSONSerialization.data(withJSONObject: ["message": message])
            transport = RequestRecordingCleanupTransport(chatBody: body, streamFailure: URLError(.timedOut))
        case .openAIComplete:
            config.provider = "openai"
            config.remote.baseURL = "http://127.0.0.1:1234/v1"
            config.remote.model = "test"
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])
            transport = RequestRecordingCleanupTransport(chatBody: body)
        }
        let service = CleanupService(config: config, transport: transport)
        return await service.clean(raw)
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

private final class RequestRecordingCleanupTransport: CleanupTransport {
    let requests = LockedTestValue<[URLRequest]>([])
    let streamFreshness = LockedTestValue<[Bool]>([])
    private let warmed: XCTestExpectation?
    private let frames: [String]
    private let chatBody: Data
    private let streamFailure: URLError?
    private let retryFrames: [String]

    init(warmed: XCTestExpectation? = nil, frames: [String] = [], chatBody: Data = Data(),
         streamFailure: URLError? = nil, retryFrames: [String] = []) {
        self.warmed = warmed
        self.frames = frames
        self.chatBody = chatBody
        self.streamFailure = streamFailure
        self.retryFrames = retryFrames
    }

    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        requests.update { $0.append(request) }
        return (probing ? Data() : chatBody, try response(for: request))
    }

    func streamLines(for request: URLRequest, freshConnection: Bool) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        requests.update { $0.append(request) }
        streamFreshness.update { $0.append(freshConnection) }
        let lines = AsyncThrowingStream<String, Error> { continuation in
            for frame in freshConnection ? retryFrames : frames { continuation.yield(frame) }
            continuation.finish(throwing: freshConnection ? nil : streamFailure)
        }
        return (lines, try response(for: request))
    }

    func sendWarmUp(_ request: URLRequest) {
        requests.update { $0.append(request) }
        warmed?.fulfill()
    }

    private func response(for request: URLRequest) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(request.url)
        return try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
}
