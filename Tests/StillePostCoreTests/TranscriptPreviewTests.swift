import XCTest
@testable import StillePostCore

final class TranscriptPreviewTests: XCTestCase {
    func testFailureNeverJoinsWordsAcrossMissingSegment() async {
        let updates = PreviewUpdates()
        let collector = SegmentCollector(onPreview: { updates.append($1) })
        let a = collector.reserveSlot(), b = collector.reserveSlot(), c = collector.reserveSlot()
        await collector.run(index: c) { "danach." }
        XCTAssertEqual(updates.last?.text, "")
        await collector.run(index: a) { "Bitte nicht" }
        XCTAssertEqual(updates.last?.text, "Bitte nicht")
        await collector.run(index: b) { throw PreviewFailure.segment }
        XCTAssertEqual(updates.last?.text, "Bitte nicht")
        XCTAssertEqual(updates.last?.hasFailedSegment, true)
        let result = await collector.finish()
        XCTAssertEqual(result, ["Bitte nicht", nil, "danach."])
    }

    func testReverseCompletionReleasesOnlyContiguousPrefixAndBoundsUnicode() async {
        let updates = PreviewUpdates()
        let collector = SegmentCollector(onPreview: { updates.append($1) })
        let indices = (0..<3).map { _ in collector.reserveSlot() }
        await collector.run(index: indices[2]) { "drei." }
        await collector.run(index: indices[1]) { "zwei" }
        XCTAssertEqual(updates.last?.text, "")
        await collector.run(index: indices[0]) { "eins" }
        XCTAssertEqual(updates.last?.text, "eins zwei drei.")
        let large = String(repeating: "👩🏽‍💻ä", count: 800) + " Schluss."
        let preview = DictationTranscriptPreview(text: large)
        XCTAssertEqual(preview.text.count, 600)
        XCTAssertTrue(preview.text.hasSuffix(" Schluss."))
        XCTAssertTrue(preview.isTruncated)
        XCTAssertFalse(preview.hasFailedSegment)
    }

    func testOldAndMalformedConfigRemainOffAndVocabularyMergePreservesOption() throws {
        for json in [#"{}"#, #"{"ui":{"sounds":false}}"#, #"{"ui":{"liveTranscriptPreview":"yes"}}"#] {
            let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            XCTAssertFalse(config.ui.liveTranscriptPreview)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = ConfigFile(url: directory.appendingPathComponent("config.json"))
        var initial = Config(); initial.ui.liveTranscriptPreview = true
        try file.save(initial)
        let stale = try file.load()
        _ = try file.addVocabulary(term: "PreviewFachbegriff", variant: nil)
        XCTAssertTrue(try file.load().ui.liveTranscriptPreview)
        var edited = stale; edited.ui.liveTranscriptPreview = false
        XCTAssertThrowsError(try file.save(edited, expected: stale))
        XCTAssertTrue(try file.load().ui.liveTranscriptPreview)
    }
}
private enum PreviewFailure: Error { case segment }
private final class PreviewUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DictationTranscriptPreview] = []
    func append(_ value: DictationTranscriptPreview) { lock.withLock { values.append(value) } }
    var last: DictationTranscriptPreview? { lock.withLock { values.last } }
}
