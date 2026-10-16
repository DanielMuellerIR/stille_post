import XCTest
@testable import StillePostCore

final class PasteTargetPolicyTests: XCTestCase {
    private let editor = PasteTargetPolicy.ApplicationIdentity(
        processIdentifier: 120, bundleIdentifier: "example.editor"
    )

    func testOnlyTheSameApplicationWindowAndFieldAllowPaste() {
        XCTAssertEqual(decide(), .paste)
        XCTAssertEqual(decide(window: .same, field: .different), .clipboardOnlyTargetChanged)
        XCTAssertEqual(decide(window: .different, field: .same), .clipboardOnlyTargetChanged)
    }

    func testApplicationSwitchAndRelaunchCannotReuseTheOriginalTarget() {
        let other = PasteTargetPolicy.ApplicationIdentity(processIdentifier: 121, bundleIdentifier: "example.other")
        let relaunched = PasteTargetPolicy.ApplicationIdentity(processIdentifier: 122, bundleIdentifier: editor.bundleIdentifier)
        XCTAssertEqual(decide(current: other), .clipboardOnlyTargetChanged)
        XCTAssertEqual(decide(current: relaunched), .clipboardOnlyTargetChanged)
    }

    func testMissingWindowOrFieldNeverAllowsApplicationOnlyPaste() {
        XCTAssertEqual(decide(window: .unavailable), .clipboardOnlyTargetUnavailable)
        XCTAssertEqual(decide(field: .unavailable), .clipboardOnlyTargetUnavailable)
        XCTAssertEqual(decide(window: .unavailable, field: .different), .clipboardOnlyTargetChanged)
        for applications in [(nil, editor as PasteTargetPolicy.ApplicationIdentity?), (editor as PasteTargetPolicy.ApplicationIdentity?, nil)] {
            XCTAssertEqual(PasteTargetPolicy.decide(
                originalApplication: applications.0, currentApplication: applications.1,
                window: .same, field: .same,
                accessibilityGranted: true, screenSharingActive: false
            ), .clipboardOnlyTargetUnavailable)
        }
    }

    func testScreenSharingAlwaysRequiresManualPaste() {
        XCTAssertEqual(PasteTargetPolicy.decide(
            originalApplication: nil, currentApplication: nil,
            window: .unavailable, field: .unavailable,
            accessibilityGranted: true, screenSharingActive: true
        ), .clipboardOnlyScreenSharing)
        XCTAssertEqual(decide(screenSharing: true), .clipboardOnlyScreenSharing)
    }

    func testMissingAccessibilityPermissionCannotSendPaste() {
        XCTAssertEqual(decide(permission: false), .noPermission)
        XCTAssertEqual(decide(permission: false, screenSharing: true), .noPermission)
    }

    private func decide(
        current: PasteTargetPolicy.ApplicationIdentity? = nil,
        window: PasteTargetPolicy.ElementMatch = .same,
        field: PasteTargetPolicy.ElementMatch = .same,
        permission: Bool = true,
        screenSharing: Bool = false
    ) -> PasteTargetPolicy.Decision {
        PasteTargetPolicy.decide(
            originalApplication: editor, currentApplication: current ?? editor,
            window: window, field: field,
            accessibilityGranted: permission, screenSharingActive: screenSharing
        )
    }
}
