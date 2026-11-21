import XCTest
@testable import StillePost
import AppKit
import StillePostCore

final class PasteRegressionTests: XCTestCase {
    @MainActor func testPasteChecksTargetAndClipboardDuringHandoff() async throws {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            throw XCTSkip("Für diese Probe wird die Prozessidentität einer laufenden Finder-Instanz benötigt.")
        }
        let window = AXUIElementCreateApplication(100001)
        let fieldA = AXUIElementCreateApplication(100002)
        let fieldB = AXUIElementCreateApplication(100003)
        let otherWindow = AXUIElementCreateApplication(100004)
        let board = NSPasteboard(name: .init("stillepost-regression-\(UUID())"))
        defer { board.releaseGlobally() }
        var focusedField: AXUIElement? = fieldA
        let fieldRole = FieldRole()
        var focusedWindow = window
        var onRole: (() -> Void)?
        var sent = 0
        var trusted = true
        var valueSettable = true
        var access = PasteService.Access()
        access.pasteboard = board
        access.frontmost = { application }
        access.trusted = { trusted }
        access.sendPaste = { sent += 1 }
        access.isSettable = { name, _, _ in name == kAXValueAttribute && valueSettable }
        access.read = { name, _, _ in
            switch name {
            case kAXFocusedWindowAttribute: return focusedWindow
            case kAXFocusedUIElementAttribute: return focusedField
            case kAXRoleAttribute:
                onRole?()
                return fieldRole.value as CFString
            case kAXWindowAttribute: return window
            default: return nil
            }
        }
        var target = PasteService.captureTarget(access: access)
        XCTAssertTrue(target != nil)
        func attempt(_ expected: PasteService.Outcome, _ label: String) {
            let prior = sent
            let outcome = PasteService.paste("Künstliches Diktat 128.", target: target, access: access)
            XCTAssertTrue(outcome == expected, "\(label): \(outcome), erwartet \(expected)")
            XCTAssertTrue(sent == prior + (expected == .pasted ? 1 : 0), label)

        }
        attempt(.pasted, "Normalfall")
        onRole = { focusedField = fieldB }
        attempt(.clipboardOnlyTargetChanged, "Feldwechsel während AX-Metadaten")
        focusedField = fieldA
        onRole = { focusedWindow = otherWindow }
        attempt(.clipboardOnlyTargetChanged, "Fensterwechsel während AX-Metadaten")
        focusedWindow = window
        onRole = {
            board.clearContents()
            board.setString("Fremde neue Kopieraktion", forType: .string)
        }
        attempt(.clipboardChanged, "Fremde Zwischenablage während AX-Metadaten")
        XCTAssertTrue(board.string(forType: .string) == "Fremde neue Kopieraktion")
        onRole = { Thread.sleep(forTimeInterval: 0.26) }
        attempt(.clipboardOnlyTargetUnavailable, "AX-Zeitbudget ausgeschöpft")
        onRole = nil
        focusedField = nil
        attempt(.clipboardOnlyTargetUnavailable, "Erkanntes Feld verschwindet")
        target = PasteService.captureTarget(access: access)
        attempt(.pasted, "App ohne AX-Fokusfeld im selben Fenster")
        focusedWindow = otherWindow
        attempt(.clipboardOnlyTargetChanged, "App ohne AX-Fokusfeld wechselt Fenster")
        focusedWindow = window
        focusedField = fieldA
        attempt(.clipboardOnlyTargetUnavailable, "AX-Fokusfeld erscheint erst später")
        fieldRole.value = kAXButtonRole
        target = PasteService.captureTarget(access: access)
        attempt(.clipboardOnlyTargetUnavailable, "Erkannter Button ist kein Textfeld")
        fieldRole.value = "AXWebArea"
        target = PasteService.captureTarget(access: access)
        attempt(.pasted, "Editierbarer Mail-HTML-Nachrichtentext")
        focusedField = fieldB
        attempt(.clipboardOnlyTargetChanged, "HTML-Editor wechselt das Fokusfeld")
        focusedField = fieldA
        focusedWindow = otherWindow
        attempt(.clipboardOnlyTargetChanged, "HTML-Editor wechselt das Fenster")
        focusedWindow = window
        valueSettable = false
        attempt(.clipboardOnlyTargetUnavailable, "HTML-Editor verliert Schreibzugriff")
        target = PasteService.captureTarget(access: access)
        attempt(.clipboardOnlyTargetUnavailable, "Nicht editierbarer HTML-Inhalt")
        fieldRole.value = kAXTextAreaRole
        target = PasteService.captureTarget(access: access)
        trusted = false
        attempt(.noPermission, "Berechtigung fehlt")
        print("Keine Fenster aktiviert, keine Tastendrücke versandt; eigene benannte Zwischenablage.")
    }
}

@MainActor private final class FieldRole {
    var value = kAXTextAreaRole
}
