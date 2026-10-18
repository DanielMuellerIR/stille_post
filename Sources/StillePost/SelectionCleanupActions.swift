import AppKit
import StillePostCore

/// Services liefern eine ausdrückliche Auswahl auf einem eigenen Pasteboard.
/// Ohne Rückgabetyp kann macOS das Ergebnis nicht automatisch zurückschreiben.
@MainActor final class SelectionCleanupActions: NSObject, NSMenuItemValidation {
    private let window = SelectionCleanupWindowController()
    private let canStart: () -> Bool
    private let configuration: () throws -> Config
    init(canStart: @escaping () -> Bool, configuration: @escaping () throws -> Config = { try ConfigFile().loadSnapshot() }) {
        self.canStart = canStart; self.configuration = configuration
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { canStart() }
    func close() { window.dismiss() }
    @objc func cleanSelectedText(_ sender: Any?) {
        guard canStart() else { return }
        if window.hasRequest { window.focus(); return }
        do { try start(SelectedTextAccess.capture()) }
        catch { window.showFailure(error) }
    }
    @objc func cleanSelectedTextService(_ pasteboard: NSPasteboard, userData: String?,
                                       error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard canStart(), !window.hasRequest else {
            error?.pointee = SelectionCleanupFailure.busy.localizedDescription as NSString
            if window.hasRequest { window.focus() }
            return
        }
        do {
            guard pasteboard.name != .general, let text = pasteboard.string(forType:.string)
                ?? pasteboard.string(forType:NSPasteboard.PasteboardType("NSStringPboardType")) else {
                throw SelectionCleanupFailure.noTarget
            }
            try start(SelectedTextAccess.capture(serviceText:text))
        } catch let failure {
            error?.pointee = failure.localizedDescription as NSString
            window.showFailure(failure)
        }
    }
    private func start(_ capture: SelectedTextAccess.Capture) throws {
        let frozen: Config
        do { frozen = try configuration() }
        catch { throw SelectionCleanupFailure.configuration }
        try window.start(capture,configuration:frozen)
    }
}
