import AppKit

// Einstiegspunkt der Menüleisten-App. Klassisches AppKit-Setup ohne Storyboard:
// NSApplication erzeugen, unseren Delegate setzen, Hauptschleife starten.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
