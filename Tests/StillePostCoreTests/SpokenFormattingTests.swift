import XCTest
@testable import StillePostCore

final class SpokenFormattingTests: XCTestCase {
    func testExplicitGermanAndEnglishCommandsPreserveAllOtherWords() throws {
        for (raw, expected) in [
            ("Eins. Format neuer Absatz. Zwei 128, nicht 256. Format neue Zeile Drei.", "Eins.\n\nZwei 128, nicht 256.\nDrei."),
            ("One. FORMAT: new paragraph. Two 128, not 256. format new line Three.", "One.\n\nTwo 128, not 256.\nThree."),
            ("🙂 Format neue Zeile Café 1.2.", "🙂\nCafé 1.2."),
            ("Format neuer Absatz Eins.", "\n\nEins."),
            ("One. format new line", "One.\n"),
            ("Eins Format. neue. Zeile. Zwei.", "Eins\nZwei.")
        ] {
            let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
            XCTAssertEqual(plan.render(plan.annotated), expected)
            XCTAssertEqual(plan.shadow(plan.annotated), raw)
            XCTAssertTrue(plan.changesFormatting)
        }
        XCTAssertNil(SpokenFormattingPlan("Neuer Absatz ist normaler Inhalt, new line ebenfalls."))
        XCTAssertNil(SpokenFormattingPlan("Formatierung neue Zeile und format new lines sind keine Befehle."))
        XCTAssertNil(SpokenFormattingPlan("Format neuer Absatz. Format neue Zeile."))
    }

    func testQuotedAndExplicitLiteralPassagesCannotExecuteCommandsOrBeRewritten() throws {
        for raw in ["„Format neue Zeile, 128 nicht 256“", "\"format new paragraph, not 256\"", "'Format neuer Absatz'", "„Offenes Zitat Format neue Zeile"] {
            let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
            XCTAssertFalse(plan.changesFormatting)
            XCTAssertEqual(plan.render(plan.annotated), raw)
            let changed = plan.annotated.replacingOccurrences(of: raw, with: "999 verändert")
            XCTAssertEqual(plan.render(changed), raw)
            XCTAssertEqual(plan.shadow(changed), raw)
        }
        let raw = "Vorher. Format wörtlich Anfang Format neue Zeile 128, nicht 256 Format wörtlich Ende. Danach."
        let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
        XCTAssertEqual(plan.render(plan.annotated), "Vorher. Format neue Zeile 128, nicht 256. Danach.")
        XCTAssertEqual(plan.shadow(plan.annotated), raw)
        let english = try XCTUnwrap(SpokenFormattingPlan("format literal start format new line, 128 not 256 format literal end"))
        XCTAssertEqual(english.render(english.annotated), "format new line, 128 not 256")
        let open = "Format wörtlich Anfang Format neue Zeile 128"
        XCTAssertEqual(try XCTUnwrap(SpokenFormattingPlan(open)).localText, open)
    }

    func testMarkerLossDuplicationChangeAndReorderingAreRejected() throws {
        let plan = try XCTUnwrap(SpokenFormattingPlan("Eins Format neue Zeile zwei Format neuer Absatz drei"))
        let expression = try NSRegularExpression(pattern: "⟦[^⟧]+⟧")
        let ranges = expression.matches(in: plan.annotated, range: NSRange(plan.annotated.startIndex..., in: plan.annotated)).map(\.range)
        let tokens = ranges.map { (plan.annotated as NSString).substring(with: $0) }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertNil(plan.render(plan.annotated.replacingOccurrences(of: tokens[0], with: "")))
        XCTAssertNil(plan.render(plan.annotated + tokens[0]))
        XCTAssertNil(plan.render(plan.annotated.replacingOccurrences(of: tokens[0], with: tokens[0].lowercased())))
        let changed = plan.annotated.replacingOccurrences(of: tokens[0], with: "SWAP").replacingOccurrences(of: tokens[1], with: tokens[0]).replacingOccurrences(of: "SWAP", with: tokens[1])
        XCTAssertNil(plan.render(changed))
    }

    func testValidationShadowContainsNoMarkerBudgetAndAppliesOnlyConfirmedOutsideVariants() throws {
        let raw = "Whis per Format neue Zeile „Whis per Format neuer Absatz“"
        let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
        var config = Config.Cleanup()
        config = try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: config)
        XCTAssertEqual(plan.expectedForValidation(config), "Whisper Format neue Zeile „Whis per Format neuer Absatz“")
        XCTAssertEqual(plan.shadow(plan.annotated), raw)
        XCTAssertFalse(plan.expectedForValidation(config).contains("⟦SP"))
        let apostrophe = try XCTUnwrap(SpokenFormattingPlan("Don't restart. format new line O'Neill stays."))
        XCTAssertEqual(apostrophe.render(apostrophe.annotated), "Don't restart.\nO'Neill stays.")
    }
}
