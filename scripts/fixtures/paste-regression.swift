import AppKit
import StillePostCore

@main
struct PasteRegression {
    static func main() {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            fatalError("Die Probe benötigt eine laufende Finder-Instanz, aktiviert sie aber nicht.")
        }
        let window = AXUIElementCreateApplication(100001)
        let fieldA = AXUIElementCreateApplication(100002)
        let fieldB = AXUIElementCreateApplication(100003)
        let otherWindow = AXUIElementCreateApplication(100004)
        let board = NSPasteboard(name: .init("stillepost-regression-\(UUID())"))
        defer { board.releaseGlobally() }
        var focusedField = fieldA
        var focusedWindow = window
        var onRole: (() -> Void)?
        var sent = 0
        var trusted = true
        var access = PasteService.Access()
        access.pasteboard = board
        access.frontmost = { application }
        access.trusted = { trusted }
        access.sendPaste = { sent += 1 }
        access.read = { name, _, _ in
            switch name {
            case kAXFocusedWindowAttribute: return focusedWindow
            case kAXFocusedUIElementAttribute: return focusedField
            case kAXRoleAttribute:
                onRole?()
                return kAXTextAreaRole as CFString
            case kAXWindowAttribute: return window
            default: return nil
            }
        }
        let target = PasteService.captureTarget(access: access)
        precondition(target != nil)
        func attempt(_ expected: PasteService.Outcome, _ label: String) {
            let prior = sent
            let outcome = PasteService.paste("Künstliches Diktat 128.", target: target, access: access)
            precondition(outcome == expected, "\(label): \(outcome), erwartet \(expected)")
            precondition(sent == prior + (expected == .pasted ? 1 : 0), label)
            print("PASS \(label)")
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
        precondition(board.string(forType: .string) == "Fremde neue Kopieraktion")
        onRole = { Thread.sleep(forTimeInterval: 0.26) }
        attempt(.clipboardOnlyTargetUnavailable, "AX-Zeitbudget ausgeschöpft")
        onRole = nil
        trusted = false
        attempt(.noPermission, "Berechtigung fehlt")
        print("Keine Fenster aktiviert, keine Tastendrücke versandt; eigene benannte Zwischenablage.")
    }
}
