import XCTest
@testable import StillePostCore

final class ResultDeliveryTests: XCTestCase {
    func testFailedOrEmptyResultsDoNotReplaceTheLastUsableText() {
        var store = TransientResultStore()
        let accepted = store.accept(text: "Der bisherige Text.", rawFallback: false)
        XCTAssertNotNil(accepted)
        XCTAssertNil(store.accept(text: " \n\t", rawFallback: false))
        XCTAssertNil(store.accept(text: "Fehlgeschlagenes Ergebnis", rawFallback: true, failed: true))
        XCTAssertEqual(store.last, accepted)
    }

    func testRawFallbackRetainsTheCompleteTextAndItsWarning() {
        var store = TransientResultStore()
        let text = "  Nein, das ist nicht vereinbart.\n128 Euro.  "
        store.accept(text: text, rawFallback: true)
        XCTAssertEqual(store.last?.text, text)
        XCTAssertEqual(store.last?.rawFallback, true)
        XCTAssertNil(TransientResultStore().last)
    }

    func testOldConfigurationKeepsDirectOutputAndAvoidsARecallShortcutCollision() throws {
        let old = #"{"hotkey":{"keyCode":15,"modifiers":["option","command"]},"ui":{"sounds":false}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        XCTAssertFalse(config.ui.previewBeforePaste)
        XCTAssertFalse(config.ui.sounds)
        XCTAssertFalse(config.hotkey.matches(config.lastResultHotkey))
        XCTAssertTrue(config.lastResultHotkey.modifiers.contains("shift"))
        XCTAssertNoThrow(try config.validate())
    }

    func testPreviewAndRecallShortcutSurviveConfigurationRoundTrip() throws {
        var config = Config()
        config.ui.previewBeforePaste = true
        config.lastResultHotkey.keyCode = 14
        config.lastResultHotkey.modifiers = ["ctrl", "shift"]
        let restored = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored, config)
    }

    func testEquivalentOrUnsafeShortcutsCannotBeSaved() {
        var config = Config()
        config.lastResultHotkey.keyCode = config.hotkey.keyCode
        config.lastResultHotkey.modifiers = ["option", "command", "unknown"]
        XCTAssertThrowsError(try config.validate())
        config.lastResultHotkey = .lastResultDefault
        config.lastResultHotkey.modifiers = ["shift"]
        XCTAssertThrowsError(try config.validate())
        config.lastResultHotkey.modifiers = ["cmd"]
        config.lastResultHotkey.keyCode = -1
        XCTAssertThrowsError(try config.validate())
    }
}
