import XCTest

final class OfflineUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testOfflineMissingModelKeepsRecordingAndChoiceAfterRestart() throws {
        try requireFixture()
        let app = launch(language: "de")
        selectOffline(app, label: "Auf diesem iPhone")
        shot("offline-choice-de")
        reveal(app.buttons["dictation.primary"], in: app); app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Aufnahme läuft"].waitForExistence(timeout: 5))
        app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Aufnahme bereit"].waitForExistence(timeout: 5))
        app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Das lokale Modell ist nicht verfügbar."].waitForExistence(timeout: 15))
        shot("offline-missing-retained-de")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["dictation.primary"].label, "Auf diesem iPhone erkennen")
        XCTAssertTrue(app.staticTexts["Aufnahme bereit"].exists)
        reveal(app.buttons["dictation.discard"], in: app); app.buttons["dictation.discard"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Aufnahme verwerfen", "dictation.discard")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bereit für dein Diktat"].waitForExistence(timeout: 5))
    }

    func testOfflineEnglishLargeTextAndLandscape() throws {
        try requireFixture()
        let app = launch(language: "en", large: true)
        selectOffline(app, label: "On this iPhone")
        XCTAssertTrue(app.buttons["dictation.language"].exists)
        shot("offline-en-large")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        reveal(app.buttons["dictation.primary"], in: app)
        XCTAssertTrue(app.buttons["dictation.primary"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["dictation.primary"].frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(app.buttons["dictation.primary"].frame.maxY, app.windows.firstMatch.frame.maxY - 30)
        shot("offline-en-large-landscape")
    }

    func testRealLocalModelProducesCopyableTextAndReleases() throws {
        try requireSimulator()
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_OFFLINE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Benötigt eigene geprüfte Modellkopie und künstliche AAC-Datei im Simulator.")
        }
        let app = launch(language: "de")
        selectOffline(app, label: "Auf diesem iPhone")
        reveal(app.buttons["dictation.primary"], in: app); app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Aufnahme läuft"].waitForExistence(timeout: 5))
        app.buttons["dictation.primary"].tap()
        app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Dein Text ist fertig"].waitForExistence(timeout: 360))
        let result = app.staticTexts["dictation.result"]
        XCTAssertTrue(result.label.lowercased().contains("keine"))
        XCTAssertTrue(app.staticTexts["Lokaler Text · ohne LLM-Bereinigung"].exists)
        reveal(app.buttons["dictation.copy"], in: app); app.buttons["dictation.copy"].tap()
        XCTAssertEqual(app.buttons["dictation.copy"].label, "Kopiert")
        shot("offline-real-model-result-de")
        reveal(app.buttons["model.open"], in: app); app.buttons["model.open"].tap()
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["model.release"].exists)
        shot("offline-real-model-released")
    }

    func testModelRemovalPreservesPairingAndPendingRecording() throws {
        try requireSimulator()
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_OFFLINE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Benötigt eigene Modellkopie und künstliche Testkopplung im Simulator.")
        }
        let app = launch(language: "de", importPairing: true)
        app.buttons["connection.open"].tap()
        XCTAssertTrue(app.staticTexts["Ein Token liegt im Schlüsselbund dieses iPhones. Leer lassen, um es zu behalten."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["connection.fingerprint"].value as? String, String(repeating: "a", count: 64))
        app.buttons["Fertig"].tap()
        selectOffline(app, label: "Auf diesem iPhone")
        reveal(app.buttons["dictation.primary"], in: app); app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Aufnahme läuft"].waitForExistence(timeout: 5))
        app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.staticTexts["Aufnahme bereit"].waitForExistence(timeout: 5))
        reveal(app.buttons["model.open"], in: app); app.buttons["model.open"].tap()
        XCTAssertTrue(app.buttons["model.remove"].waitForExistence(timeout: 10))
        reveal(app.buttons["model.remove"], in: app); app.buttons["model.remove"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Modelldateien entfernen", "model.remove")).firstMatch.tap()
        XCTAssertTrue(app.buttons["model.download"].waitForExistence(timeout: 10))
        app.buttons["Fertig"].tap()
        XCTAssertTrue(app.staticTexts["Aufnahme bereit"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["dictation.primary"].label, "Auf diesem iPhone erkennen")
        XCTAssertTrue(app.staticTexts["Aufnahme bereit"].exists)
        app.buttons["connection.open"].tap()
        XCTAssertTrue(app.staticTexts["Ein Token liegt im Schlüsselbund dieses iPhones. Leer lassen, um es zu behalten."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["connection.address"].value as? String, "https://mac.local:8188")
        XCTAssertEqual(app.textFields["connection.fingerprint"].value as? String, String(repeating: "a", count: 64))
        reveal(app.buttons["Verbindung und Token entfernen"], in: app); app.buttons["Verbindung und Token entfernen"].tap()
        app.buttons["Fertig"].tap()
        reveal(app.buttons["dictation.discard"], in: app); app.buttons["dictation.discard"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Aufnahme verwerfen", "dictation.discard")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bereit für dein Diktat"].waitForExistence(timeout: 5))
        shot("offline-model-removal-preserved-own-fixtures")
    }

    private func requireFixture() throws {
        try requireSimulator()
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_OFFLINE_UI_TEST"] == "1" else {
            throw XCTSkip("Benötigt eigenen Simulator ohne Modell und künstliche AAC-Datei.")
        }
    }
    private func requireSimulator() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Diese künstliche Probe läuft ausschließlich im eigenen Simulator.")
        #endif
    }
    private func launch(language: String, large: Bool = false, importPairing: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["STILLEPOST_MOBILE_SYNTHETIC_CAPTURE"] = "1"
        if importPairing { app.launchEnvironment["STILLEPOST_MOBILE_IMPORT_TEST_CONNECTION"] = "1" }
        app.launch()
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        return app
    }
    private func selectOffline(_ app: XCUIApplication, label: String) {
        let choice = app.buttons["dictation.mode"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        reveal(choice, in: app)
        if !choice.label.contains(label) { choice.tap(); app.buttons[label].tap() }
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let window = app.windows.firstMatch.frame
            let top = app.navigationBars.firstMatch.frame.maxY + 4
            var downward = false
            if element.exists {
                let frame = element.frame
                if frame.minY >= top, frame.maxY <= window.maxY - 30, element.isHittable { return }
                downward = frame.minY < top && frame.height > 0
            }
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.3 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
