import XCTest

final class LocalModelUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testGermanModelScreenAndExplicitActions() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        openModel(app)
        XCTAssertTrue(app.staticTexts["Whisper large-v3-turbo"].exists)
        reveal(app.buttons["model.download"], app: app)
        XCTAssertTrue(app.buttons["model.download"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["model.download"].isEnabled)
        shot(app, "model-de-missing")
        app.buttons["Modell und Lizenzen"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "MIT License")).firstMatch.waitForExistence(timeout: 3))
        shot(app, "model-de-license")
        app.buttons["Fertig"].firstMatch.tap()
        app.buttons["Fertig"].firstMatch.tap()
        XCTAssertTrue(app.buttons["dictation.primary"].exists)
    }

    func testEnglishLargeTextModelScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); openModel(app)
        reveal(app.buttons["model.download"], app: app)
        XCTAssertTrue(app.buttons["model.download"].isHittable)
        shot(app, "model-en-large")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let size = XCUIScreen.main.screenshot().image.size
            return app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height && size.width > size.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        reveal(app.buttons["model.download"], app: app)
        XCTAssertTrue(app.buttons["model.download"].isHittable)
        shot(app, "model-en-large-landscape")
    }

    func testExplicitDownloadPauseResumeRestartAndRemoval() throws {
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_MODEL_DOWNLOAD_TEST"] == "1" else {
            throw XCTSkip("Benötigt den ausdrücklich gestarteten echten Modell-Download.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch(); openModel(app)
        if app.buttons["model.remove"].exists { removeModel(app) }
        reveal(app.buttons["model.download"], app: app); app.buttons["model.download"].tap()
        XCTAssertTrue(app.buttons["model.pause"].waitForExistence(timeout: 20))
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let prefix = app.staticTexts["model.progress"].label.components(separatedBy: " / ").first ?? ""
            return prefix.contains("MB") || prefix.contains("GB")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 90), .completed)
        app.buttons["model.pause"].tap()
        XCTAssertTrue(app.buttons["model.download"].waitForExistence(timeout: 10))
        shot(app, "model-de-paused")
        app.terminate(); app.launch(); openModel(app)
        reveal(app.buttons["model.download"], app: app)
        XCTAssertEqual(app.buttons["model.download"].label, "Download fortsetzen")
        app.buttons["model.download"].tap()
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 300))
        shot(app, "model-de-downloaded")
        app.terminate(); app.launch(); openModel(app)
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 10))
        removeModel(app)
        XCTAssertTrue(app.buttons["model.download"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["model.download"].label, "Modell herunterladen")
        shot(app, "model-de-removed")
    }

    func testInsufficientCapacityIsVisibleWithoutStartingDownload() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchEnvironment["STILLEPOST_MOBILE_MODEL_EMPTY_CAPACITY"] = "1"
        app.launch(); openModel(app)
        reveal(app.buttons["model.download"], app: app); app.buttons["model.download"].tap()
        let error = app.descendants(matching: .any)["model.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        reveal(error, app: app)
        XCTAssertTrue(error.label.contains("Nicht genügend freier Speicher"))
        XCTAssertFalse(app.buttons["model.pause"].exists)
        shot(app, "model-de-space-error")
    }

    func testDevicePreparedModelIsAvailableWithoutLoading() throws {
        try requireDeviceModelTest()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch(); openModel(app)
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["model.release"].exists)
        reveal(app.buttons["model.load"], app: app)
        shot(app, "model-device-prepared-available")
    }

    func testDeviceLoadReleaseBackgroundAndRestart() throws {
        try requireDeviceModelTest()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch(); openModel(app)
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 10))
        reveal(app.buttons["model.load"], app: app); app.buttons["model.load"].tap()
        XCTAssertTrue(app.buttons["model.release"].waitForExistence(timeout: 360))
        reveal(app.buttons["model.release"], app: app); shot(app, "model-device-loaded")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["model.release"].exists)
        shot(app, "model-device-background-released")
        reveal(app.buttons["model.load"], app: app); app.buttons["model.load"].tap()
        XCTAssertTrue(app.buttons["model.release"].waitForExistence(timeout: 360))
        reveal(app.buttons["model.release"], app: app); app.buttons["model.release"].tap()
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 30))
        shot(app, "model-device-explicit-release")
        app.terminate(); app.launch(); openModel(app)
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["model.release"].exists)
        shot(app, "model-device-restart-available")
    }

    func testDeviceRejectsDamagedModelAndRemovesItsFiles() throws {
        try requireDeviceModelTest()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch(); openModel(app)
        XCTAssertTrue(app.buttons["model.load"].waitForExistence(timeout: 10))
        reveal(app.buttons["model.load"], app: app); app.buttons["model.load"].tap()
        let error = app.descendants(matching: .any)["model.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 30))
        XCTAssertTrue(error.label.contains("unvollständig oder beschädigt"))
        XCTAssertFalse(app.buttons["model.release"].exists)
        reveal(error, app: app); shot(app, "model-device-integrity-error")
        removeModel(app)
    }

    private func requireDeviceModelTest() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Diese Probe benötigt das ausdrücklich bereitgestellte echte iPhone.")
        #else
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_DEVICE_MODEL_TEST"] == "1" else {
            throw XCTSkip("Benötigt einen abgestimmten Geräteblock mit vorbereiteten Modelldateien.")
        }
        #endif
    }

    private func openModel(_ app: XCUIApplication) {
        let button = app.buttons["model.open"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        reveal(button, app: app); button.tap()
        XCTAssertTrue(app.navigationBars["Lokales Modell"].waitForExistence(timeout: 3)
            || app.navigationBars["Local Model"].exists)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            var downward = false
            if element.exists {
                let frame = element.frame, window = app.windows.firstMatch.frame
                let bar = app.navigationBars["Lokales Modell"].exists ? app.navigationBars["Lokales Modell"]
                    : app.navigationBars["Local Model"].exists ? app.navigationBars["Local Model"] : app.navigationBars.firstMatch
                let top = bar.frame.maxY + 4
                if frame.minY >= top, frame.maxY <= window.maxY - 4, element.isHittable { return }
                downward = frame.minY < top && frame.height > 0
            }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.3 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }
    private func removeModel(_ app: XCUIApplication) {
        reveal(app.buttons["model.remove"], app: app); app.buttons["model.remove"].tap()
        let confirmation = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Modelldateien entfernen", "model.remove")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        shot(app, "model-de-remove-confirm")
        confirmation.tap()
        XCTAssertTrue(app.buttons["model.download"].waitForExistence(timeout: 10))
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
