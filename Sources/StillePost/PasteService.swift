import AppKit
import Carbon.HIToolbox
import StillePostCore

/// Fügt den fertigen Text an der aktuellen Cursor-Position ein.
///
/// Mechanik: Text in die Zwischenablage legen, ⌘V an die aktive App senden,
/// danach die vorherige Zwischenablage wiederherstellen (nach kurzer Wartezeit,
/// damit die Ziel-App das Einfügen sicher abgeschlossen hat).
///
/// Für das synthetische ⌘V braucht die App die Bedienungshilfen-Berechtigung
/// (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen).
enum PasteService {

    /// Prüft die Berechtigung und zeigt beim ersten Mal den System-Hinweis an.
    static func ensureAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Bundle-IDs von Bildschirmfreigabe-Viewern: Ist so einer vorn, werden unsere
    /// Tastendrücke an einen ENTFERNTEN Mac weitergereicht — das braucht
    /// Sonderbehandlung (s. paste()).
    private static let screenSharingBundleIDs: Set<String> = [
        "com.apple.ScreenSharing",   // macOS Bildschirmfreigabe
        "com.apple.RemoteDesktop",   // Apple Remote Desktop
    ]

    /// Ergebnis eines Einfüge-Versuchs (die App wählt danach den Overlay-Hinweis).
    enum Outcome {
        /// Text wurde per synthetischem ⌘V eingefügt.
        case pasted
        /// Bildschirmfreigabe ist vorn: NICHT getippt — der Text liegt in der
        /// Zwischenablage und wandert über den geteilten Sync zum entfernten Mac;
        /// dort muss der Nutzer selbst ⌘V drücken. (Synthetische ⌘-Events werden
        /// von der Bildschirmfreigabe nicht als Modifier weitergereicht — am
        /// anderen Ende kam nur ein nacktes "v" an; real getestet mit echten
        /// ⌘-Down/-Up-Events, half nicht.)
        case clipboardOnlyScreenSharing
        /// Bedienungshilfen-Berechtigung fehlt; Text liegt in der Zwischenablage.
        case noPermission
    }

    /// Fügt Text an der Cursor-Position ein (bzw. legt ihn für die
    /// Bildschirmfreigabe nur in die Zwischenablage — s. Outcome).
    @discardableResult
    static func paste(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general

        // Alle Items und Typen tief kopieren. Bilder, Dateien und Rich Text dürfen
        // durch ein Diktat ebenso wenig verlorengehen wie einfacher Text.
        let previous = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownChangeCount = pasteboard.changeCount

        guard AXIsProcessTrusted() else {
            // Keine Berechtigung: Text bleibt wenigstens in der Zwischenablage,
            // der Nutzer kann selbst ⌘V drücken. Kein Restore in diesem Fall!
            return .noPermission
        }

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if screenSharingBundleIDs.contains(frontmost) {
            // Bildschirmfreigabe vorn: bewusst NICHT tippen. Der geteilte
            // Zwischenablage-Sync bringt den Text auf den entfernten Mac, das
            // ECHTE ⌘V des Nutzers dort funktioniert zuverlässig. Deshalb auch
            // KEIN Restore der alten Zwischenablage — das würde den Text vor dem
            // manuellen Einfügen wieder wegsyncen.
            return .clipboardOnlyScreenSharing
        }

        postCmdV()

        // Zwischenablage nach kurzer Zeit wiederherstellen — aber nur, wenn sie
        // noch unseren Text enthält. Eine neue Kopieraktion hat Vorrang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            previous.restore(to: pasteboard, ifChangeCountIs: ownChangeCount)
        }
        return .pasted
    }

    /// Sendet ⌘V als VOLLSTÄNDIGE Ereignisfolge inklusive echter ⌘-Tastendrücke
    /// (robuster als nur das ⌘-Flag auf dem V-Event; manche Empfänger verfolgen
    /// den Modifier-Zustand über eigene Ereignisse).
    private static func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let sequence: [(key: Int, down: Bool, flags: CGEventFlags)] = [
            (kVK_Command, true, .maskCommand),
            (kVK_ANSI_V, true, .maskCommand),
            (kVK_ANSI_V, false, .maskCommand),
            (kVK_Command, false, []),
        ]
        for step in sequence {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(step.key), keyDown: step.down)
            event?.flags = step.flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
