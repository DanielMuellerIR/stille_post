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

    func testMarkerCannotMoveAcrossContentWithoutChangingItsIdentity() throws {
        let plan = try XCTUnwrap(SpokenFormattingPlan("Alpha Format neue Zeile Beta"))
        let expression = try NSRegularExpression(pattern: "⟦[^⟧]+⟧")
        let match = try XCTUnwrap(expression.firstMatch(in: plan.annotated, range: NSRange(plan.annotated.startIndex..., in: plan.annotated)))
        let marker = (plan.annotated as NSString).substring(with: match.range)
        XCTAssertNil(plan.restoringLiterals("Alpha Beta " + marker))
        XCTAssertNil(plan.restoringLiterals(marker + " Alpha Beta"))
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

    func testListsHaveExplicitTransitionsAndKeepBoundaryBreaks() throws {
        for (raw, expected) in [
            ("Vorher. Format Liste Anfang 128, nicht 256. Format Listenpunkt Whisper 1.2. Format Liste Ende Danach.", "Vorher.\n• 128, nicht 256.\n• Whisper 1.2.\nDanach."),
            ("format list start One. format bullet point Two. format list end", "• One.\n• Two.\n"),
            ("Format Liste Anfang 🙂 Café. Format neue Zeile 1.2 bleibt. Format Listenpunkt Straße", "• 🙂 Café.\n1.2 bleibt.\n• Straße"),
            ("format list start One. format list end format new paragraph Two. format list start Three.", "• One.\n\n\nTwo.\n• Three."),
            ("Format neuer Absatz Format Liste Anfang Eins Format Liste Ende Format neue Zeile", "\n\n• Eins\n\n"),
            ("Format. Liste. Anfang. Eins Format, Listenpunkt. Zwei Format: Liste: Ende. Drei", "• Eins\n• Zwei\nDrei")
        ] {
            let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
            XCTAssertEqual(plan.render(plan.annotated), expected, raw)
            XCTAssertEqual(plan.shadow(plan.annotated), raw)
            XCTAssertTrue(plan.changesFormatting)
        }
    }

    func testMalformedListsAndCommandOnlySequencesLoseNoWords() throws {
        for raw in [
            "Format Liste Anfang Format Listenpunkt Format Liste Ende",
            "format list start format new line format list end",
            "Format Liste Anfang Eins Format Liste Anfang Zwei Format Liste Ende Format Liste Ende",
            "format list start One format bullet point format list end",
            "format list start One format bullet point",
            "Format Listenpunkt Format Liste Ende",
            "Format Anführungszeichen Anfang Format Anführungszeichen Ende"
        ] {
            let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
            XCTAssertFalse(plan.changesFormatting, raw)
            XCTAssertEqual(plan.render(plan.annotated), raw)
        }
        for raw in ["Liste Anfang, Listenpunkt und Anführungszeichen Ende sind Wörter.",
                    "format bullet points and format quote starts are ordinary words."] {
            XCTAssertNil(SpokenFormattingPlan(raw))
        }
        XCTAssertNil(SpokenFormattingPlan("format new paragraph format new line"))
    }

    func testSpokenQuotesProtectEveryInnerCommandAndExactUnicode() throws {
        let body = "🙂 Cafe\u{301}\n  Format Listenpunkt 128, nicht 256. Format neue Zeile"
        let raw = "Vorher Format Anführungszeichen Anfang " + body + " Format Anführungszeichen Ende. Danach."
        let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
        XCTAssertEqual(plan.render(plan.annotated), "Vorher „" + body + "“. Danach.")
        XCTAssertEqual(Array(try XCTUnwrap(plan.render(plan.annotated)).utf8), Array(("Vorher „" + body + "“. Danach.").utf8))
        XCTAssertEqual(plan.render(plan.annotated.replacingOccurrences(of: body, with: "999")), "Vorher „" + body + "“. Danach.")
        XCTAssertEqual(plan.shadow(plan.annotated), raw)
        for (input, expected) in [
            ("format quote start don't change O’Neill, 1.2 format quote end", "“don't change O’Neill, 1.2”"),
            ("format quote start Format Liste Anfang Format wörtlich Anfang format quote end", "“Format Liste Anfang Format wörtlich Anfang”"),
            ("Format Liste Anfang format quote start format bullet point format quote end Format Liste Ende", "• “format bullet point”\n"),
            ("Format Anführungszeichen Anfang Eins format quote end", "„Eins“")
        ] {
            let next = try XCTUnwrap(SpokenFormattingPlan(input))
            XCTAssertEqual(next.render(next.annotated), expected)
        }
    }

    func testOpenNestedOrQuotedQuoteCommandsRemainLiteral() throws {
        for raw in [
            "format quote start One format new paragraph Two",
            "Format Anführungszeichen Anfang Eins Format Anführungszeichen Anfang Zwei Format Anführungszeichen Ende Drei Format Anführungszeichen Ende",
            "format quote start One format quote start Two format quote end",
            "Format Anführungszeichen Ende",
            "„Format Anführungszeichen Anfang Eins Format Anführungszeichen Ende“",
            "\"format list start One format bullet point Two format list end\""
        ] {
            let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
            XCTAssertFalse(plan.changesFormatting, raw)
            XCTAssertEqual(plan.localText, raw)
        }
        let raw = "Format wörtlich Anfang Format Liste Anfang 128 Format Anführungszeichen Anfang Nein Format wörtlich Ende"
        let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
        XCTAssertEqual(plan.render(plan.annotated), "Format Liste Anfang 128 Format Anführungszeichen Anfang Nein")
    }

    func testPositionsAcceptCleanupOnlyWithinTheirOriginalSpans() throws {
        var config = Config.Cleanup()
        config = try VocabularyRules.adding(term: "Whisper", variant: "Whis per", to: config)
        let plan = try XCTUnwrap(SpokenFormattingPlan("ähm Whis per Whis per Format neue Zeile Café 🙂 nicht 128"))
        let input = plan.modelInput(config)
        XCTAssertNotNil(plan.restoringLiterals(input.replacingOccurrences(of: "ähm Whisper Whisper", with: "Whisper"), cleanup: config))
        let expression = try NSRegularExpression(pattern: "⟦[^⟧]+⟧")
        let match = try XCTUnwrap(expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)))
        let marker = (input as NSString).substring(with: match.range)
        for candidate in [
            "Whisper Café " + marker + " 🙂 nicht 128",
            "Whisper 🙂 " + marker + " Café nicht 128",
            "Whisper " + marker + " Café 🙂 128",
            input + "⟦SPFAKEN0⟧",
            input.replacingOccurrences(of: "128", with: "256")
        ] { XCTAssertNil(plan.restoringLiterals(candidate, cleanup: config)) }
        XCTAssertTrue(CleanupService.preservesFormattingPosition(raw: "didn't restart", cleaned: "did not restart"))
        XCTAssertFalse(CleanupService.preservesFormattingPosition(raw: "128 128", cleaned: "128"))
    }

    func testCommandsAreRecognizedAfterOrderedSegmentsAndWithDecomposedUnicode() throws {
        let segments = ["Format Liste", "Anfang Eins Format Listenpunkt Format Anfu\u{308}hrungszeichen", "Anfang Cafe\u{301} Format neue Zeile Format Anfu\u{308}hrungszeichen Ende Format Liste Ende"]
        let raw = segments.joined(separator: " ")
        let plan = try XCTUnwrap(SpokenFormattingPlan(raw))
        XCTAssertEqual(plan.render(plan.annotated), "• Eins\n• „Cafe\u{301} Format neue Zeile“\n")
        XCTAssertEqual(plan.shadow(plan.annotated), raw)
    }
}
