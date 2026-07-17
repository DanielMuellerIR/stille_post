import XCTest
@testable import StillePostCore

final class LocalizationTests: XCTestCase {

    func testGermanAndEnglishContainTheSameKeys() {
        let german = L10n.keys(language: "de")
        let english = L10n.keys(language: "en")

        XCTAssertFalse(german.isEmpty)
        XCTAssertEqual(german, english)
    }

    func testRepresentativeEnglishTranslations() {
        XCTAssertEqual(
            L10n.text("window.settings.title", language: "en"),
            "Stille Post — Settings"
        )
        XCTAssertEqual(
            L10n.text("overlay.recording", language: "en"),
            "RECORDING"
        )
        XCTAssertEqual(
            L10n.text("cli.doctor.ready", language: "en"),
            "Everything is ready."
        )
    }

    func testFormatPlaceholdersMatchBetweenLanguages() throws {
        let pattern = #"%[-+0 #]*(?:\d+|\*)?(?:\.\d+)?(?:ll|l|h)?[@dDuUxXfFeEgGcCsSp%]"#
        let expression = try NSRegularExpression(pattern: pattern)

        for key in L10n.keys(language: "de") {
            let german = L10n.text(key, language: "de")
            let english = L10n.text(key, language: "en")
            XCTAssertEqual(
                placeholders(in: german, using: expression),
                placeholders(in: english, using: expression),
                "Formatplatzhalter unterscheiden sich für \(key)"
            )
        }
    }

    private func placeholders(in text: String, using expression: NSRegularExpression) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
