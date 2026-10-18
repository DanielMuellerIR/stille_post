import XCTest

final class MobileUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func testConnectionAndAccessibleMainAction() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        app.buttons["connection.open"].tap()
        XCTAssertTrue(app.textFields["connection.address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["connection.token"].exists)
        XCTAssertTrue(app.switches["connection.development"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "connection-de"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRecordingRetryRecoveryCopyAndCancel() throws {
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_BRIDGE_UI_TEST"] == "1" else {
            throw XCTSkip("Benötigt vorbereiteten isolierten HTTP-Testserver und private Container-Konfiguration.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchEnvironment["STILLEPOST_MOBILE_IMPORT_TEST_CONNECTION"] = "1"
        app.launchEnvironment["STILLEPOST_MOBILE_SYNTHETIC_CAPTURE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        shot(app, "idle-de")
        app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Aufnahme läuft")
        shot(app, "recording-de")
        sleep(2)
        app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Aufnahme bereit")
        shot(app, "ready-de")
        app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Diktat unterbrochen")
        shot(app, "error-retained-de")
        app.terminate(); app.launch()
        waitForPhase(app, "Aufnahme bereit")
        XCTAssertTrue(app.staticTexts["Eine vorherige Aufnahme wurde wiedergefunden. Es wird nichts automatisch gesendet."].exists)
        app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Dein Text ist fertig")
        XCTAssertTrue(app.staticTexts["dictation.result"].label.contains("zwölf Kopien"))
        reveal(app.buttons["dictation.copy"], in: app); app.buttons["dictation.copy"].tap()
        XCTAssertEqual(app.buttons["dictation.copy"].label, "Kopiert")
        shot(app, "result-de")
        reveal(app.buttons["dictation.primary"], in: app); app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Aufnahme läuft"); sleep(1)
        app.buttons["dictation.primary"].tap(); waitForPhase(app, "Aufnahme bereit")
        app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.buttons["dictation.cancelUpload"].waitForExistence(timeout: 5))
        shot(app, "sending-de")
        app.buttons["dictation.cancelUpload"].tap(); waitForPhase(app, "Aufnahme bereit")
        app.buttons["dictation.discard"].tap()
        app.sheets.buttons["Aufnahme verwerfen"].tap()
        waitForPhase(app, "Bereit für dein Diktat")
    }

    func testEnglishAndLargeTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        reveal(app.buttons["dictation.primary"], in: app)
        XCTAssertTrue(app.buttons["dictation.primary"].isHittable)
        shot(app, "main-en-large")
        app.buttons["connection.open"].tap()
        XCTAssertTrue(app.textFields["connection.address"].waitForExistence(timeout: 5))
        shot(app, "connection-en-large")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        sleep(3)
        shot(app, "connection-en-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func testDeviceMicrophoneAndBridge() throws {
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_DEVICE_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Benötigt vorbereitetes echtes iPhone und begleitete Sprechprobe.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchEnvironment["STILLEPOST_MOBILE_IMPORT_TEST_CONNECTION"] = "1"
        app.launch()
        defer { showHome() }
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        if app.buttons["dictation.discard"].exists {
            app.buttons["dictation.discard"].tap(); app.sheets.buttons["Aufnahme verwerfen"].tap()
        }
        app.buttons["connection.open"].tap()
        XCTAssertTrue(app.buttons["connection.check"].waitForExistence(timeout: 5))
        app.buttons["connection.check"].tap(); acceptPermissionAlert()
        let ready = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Mac bereit")).firstMatch
        if !ready.waitForExistence(timeout: 12) { app.buttons["connection.check"].tap() }
        XCTAssertTrue(ready.waitForExistence(timeout: 12))
        app.buttons["Fertig"].tap()
        app.buttons["dictation.primary"].tap(); acceptPermissionAlert()
        waitForPhase(app, "Aufnahme läuft")
        print("DEVICE_RECORDING_STARTED")
        shot(app, "device-recording-de")
        sleep(18)
        XCTAssertEqual(app.buttons["dictation.primary"].label, "Aufnahme stoppen")
        app.buttons["dictation.primary"].tap(); waitForPhase(app, "Aufnahme bereit")
        app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Dein Text ist fertig", timeout: 180)
        let text = app.staticTexts["dictation.result"].label
        XCTAssertTrue(text.lowercased().contains("keine"))
        XCTAssertTrue(text.contains("12") || text.lowercased().contains("zwölf"))
        reveal(app.buttons["dictation.copy"], in: app); app.buttons["dictation.copy"].tap()
        XCTAssertEqual(app.buttons["dictation.copy"].label, "Kopiert")
        shot(app, "device-result-de")
    }

    func testDeviceInterruptionAndConnection() throws {
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_DEVICE_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Benötigt ausdrücklich freigegebenen echten Geräteblock.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        defer { showHome() }
        XCTAssertTrue(app.buttons["dictation.primary"].waitForExistence(timeout: 10))
        if app.buttons["dictation.discard"].exists {
            app.buttons["dictation.discard"].tap(); app.sheets.buttons["Aufnahme verwerfen"].tap()
        }
        finishDeviceInterruptionAndConnectionChecks(app)
    }

    func testDeviceOversizedRecording() throws {
        let app = try preparedDeviceFileTest()
        defer { showHome() }
        app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Diktat unterbrochen")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Die Aufnahme überschreitet die Grenze")).firstMatch.exists)
        XCTAssertTrue(app.buttons["dictation.discard"].exists)
        shot(app, "device-oversized-de")
        app.buttons["dictation.discard"].tap(); app.sheets.buttons["Aufnahme verwerfen"].tap()
        waitForPhase(app, "Bereit für dein Diktat")
    }

    func testDeviceDisconnectedUpload() throws {
        let app = try preparedDeviceFileTest()
        defer { showHome() }
        app.buttons["dictation.primary"].tap()
        XCTAssertTrue(app.buttons["dictation.cancelUpload"].waitForExistence(timeout: 5))
        app.buttons["dictation.cancelUpload"].tap(); waitForPhase(app, "Aufnahme bereit")
        XCTAssertTrue(app.buttons["dictation.discard"].exists)
        app.buttons["dictation.primary"].tap(); waitForPhase(app, "Diktat unterbrochen", timeout: 20)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Der Mac ist nicht erreichbar")).firstMatch.exists)
        XCTAssertTrue(app.buttons["dictation.discard"].exists)
        shot(app, "device-disconnected-de")
        app.buttons["dictation.discard"].tap(); app.sheets.buttons["Aufnahme verwerfen"].tap()
        waitForPhase(app, "Bereit für dein Diktat")
        app.buttons["connection.open"].tap(); app.buttons["connection.check"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Der Mac ist nicht erreichbar")).firstMatch.waitForExistence(timeout: 15))
        reveal(app.buttons["Verbindung und Token entfernen"], in: app)
        app.buttons["Verbindung und Token entfernen"].tap(); app.buttons["Fertig"].tap()
    }

    private func preparedDeviceFileTest() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["STILLEPOST_RUN_DEVICE_BRIDGE_TEST"] == "1" else {
            throw XCTSkip("Benötigt vorbereitete eigene Datei und ausdrücklichen Geräteblock; startet kein Mikrofon.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launchEnvironment["STILLEPOST_MOBILE_IMPORT_TEST_CONNECTION"] = "1"
        app.launch()
        waitForPhase(app, "Aufnahme bereit")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["dictation.primary"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        return app
    }

    private func finishDeviceInterruptionAndConnectionChecks(_ app: XCUIApplication) {
        reveal(app.buttons["dictation.primary"], in: app); app.buttons["dictation.primary"].tap()
        waitForPhase(app, "Aufnahme läuft"); sleep(1)
        showHome(); sleep(2)
        XCTAssertNotEqual(app.state, .runningForeground, "Home muss die App tatsächlich verlassen")
        app.activate()
        waitForPhase(app, "Diktat unterbrochen")
        shot(app, "device-interrupted-de")
        app.buttons["dictation.discard"].tap(); app.sheets.buttons["Aufnahme verwerfen"].tap()
        waitForPhase(app, "Bereit für dein Diktat")
        app.buttons["connection.open"].tap()
        let address = app.textFields["connection.address"]
        let original = address.value as? String ?? ""
        address.tap(); address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count))
        address.typeText("http://unreachable-stillepost.local:8188")
        app.buttons["connection.save"].tap(); app.buttons["connection.check"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Der Mac ist nicht erreichbar")).firstMatch.waitForExistence(timeout: 15))
        // Nur die eigene kurzlebige Testverbindung entfernen; kein Alltags-Token wird gelesen.
        reveal(app.buttons["Verbindung und Token entfernen"], in: app)
        app.buttons["Verbindung und Token entfernen"].tap()
        app.buttons["Fertig"].tap()
    }

    private func showHome() { XCUIApplication(bundleIdentifier: "com.apple.springboard").activate() }

    private func acceptPermissionAlert() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            // Der begleitete Geräteblock lässt die Freigabe bewusst beim Nutzer;
            // kein zweiter Klick auf einen inzwischen bereits geschlossenen Dialog.
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 20), .completed)
        }
    }

    private func waitForPhase(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 30) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: app.staticTexts["dictation.phase"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        if name.contains("result") { sleep(1) }
        let screenshot = name.contains("landscape") ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
