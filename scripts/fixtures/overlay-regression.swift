import AppKit
import StillePostCore

@main
struct OverlayRegression {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let overlay = OverlayController(config: Config.UI())
        overlay.recordingContext = "Anzeigeprüfung · Deutsch"
        overlay.show(.recording)
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            if !condition { failures += 1 }
            print("\(condition ? "PASS" : "FAIL") \(label)")
        }
        func onScreen(_ panel: NSWindow) -> Bool {
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.contains { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let panel = app.windows.first(where: { $0 is ClickThroughPanel }) else {
                print("FAIL Aufnahmeoverlay fehlt"); exit(1)
            }
            check(onScreen(panel), "Aufnahmeoverlay im WindowServer sichtbar")
            // Entspricht der Lage eines Fensters auf einem entfernten Monitor.
            panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                check(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) },
                      "Bildschirmänderung holt das Overlay auf einen aktuellen Bildschirm")
                app.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    check(app.isHidden && onScreen(panel), "Ausgeblendete App behält sichtbares Aufnahmeoverlay")
                    check(frontmost == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          "Ziel-App behält den Fokus")
                    if let screenshot = CommandLine.arguments.dropFirst().first {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(panel.windowNumber), screenshot]
                        do { try capture.run(); capture.waitUntilExit(); check(capture.terminationStatus == 0, "Fensteraufnahme") }
                        catch { check(false, "Fensteraufnahme: \(error)") }
                    }
                    overlay.hide()
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
                    let deadline = Date().addingTimeInterval(2)
                    @MainActor func finishWhenHidden() {
                        if onScreen(panel), Date() < deadline {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { finishWhenHidden() }
                            return
                        }
                        check(!onScreen(panel), "Bildschirmänderung öffnet kein beendetes Overlay")
                        exit(failures == 0 ? 0 : 1)
                    }
                    finishWhenHidden()
                }
            }
        }
        withExtendedLifetime(overlay) { app.run() }
    }
}
