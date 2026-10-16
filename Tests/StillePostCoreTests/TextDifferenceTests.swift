import XCTest
@testable import StillePostCore

final class TextDifferenceTests: XCTestCase {
    private func verify(_ before: String, _ after: String, detailed: Bool = true) throws -> TextDifference.Result {
        let result = try TextDifference.compare(before, after)
        XCTAssertEqual(result.isSummarized, !detailed)
        if !result.isSummarized {
            let reconstructedBefore = result.segments.filter { $0.kind != .added }.map(\.text).joined()
            let reconstructedAfter = result.segments.filter { $0.kind != .removed }.map(\.text).joined()
            XCTAssertTrue(reconstructedBefore.utf8.elementsEqual(before.utf8))
            XCTAssertTrue(reconstructedAfter.utf8.elementsEqual(after.utf8))
        } else {
            XCTAssertTrue(result.before.utf8.elementsEqual(before.utf8))
            XCTAssertTrue(result.after.utf8.elementsEqual(after.utf8))
        }
        return result
    }

    func testWordsPunctuationWhitespaceAndUnicodeRemainExact() throws {
        for (before, after) in [("", "Hallo"), ("Weg", ""), ("gleich", "gleich"),
            ("Grüße 128, Euro.\n", "Grüße, 128 Euro!\n\n"), ("Hello\tworld.", "Hello world!"),
            ("Cafe\u{301}", "Café"), ("<b>**Text**</b>", "<b>**Text!**</b>")] {
            _ = try verify(before, after)
        }
    }

    func testLongSimilarTextUsesDetailedMiddleDifference() throws {
        let prefix = String(repeating: "Langer gemeinsamer Anfang 128. ", count: 1500)
        let suffix = String(repeating: " Gemeinsames Ende.", count: 1000)
        let result = try verify(prefix + "alt" + suffix, prefix + "neu!" + suffix)
        XCTAssertTrue(result.segments.contains { $0.kind == .removed && $0.text == "alt" })
        XCTAssertLessThan(result.segments.count, 8)
    }

    func testLargeUnrelatedTextUsesBoundedSummaryWithFullText() throws {
        _ = try verify(String(repeating: "alt 128. ", count: 1500), String(repeating: "neu 256! ", count: 1500), detailed: false)
        _ = try verify(String(repeating: "x", count: 300_000), "kurz", detailed: false)
    }

    func testCancelledComparisonDoesNotDeliverAResult() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try TextDifference.compare("alt", "neu")
        }
        do { _ = try await worker.value; XCTFail("Abbruch fehlt") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
