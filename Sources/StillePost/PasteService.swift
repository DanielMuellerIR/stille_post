import AppKit
import Carbon.HIToolbox
import StillePostCore

/// Fügt den fertigen Text nur in das beim Aufnahmebeginn erfasste Ziel ein.
///
/// Mechanik: Text in die Zwischenablage legen, ⌘V an die aktive App senden,
/// danach die vorherige Zwischenablage wiederherstellen (nach kurzer Wartezeit,
/// damit die Ziel-App das Einfügen sicher abgeschlossen hat).
///
/// Für das synthetische ⌘V braucht die App die Bedienungshilfen-Berechtigung
/// (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen).
enum PasteService {

    /// Enge Systemgrenze für zeitliche Regressionen ohne fremde Fenster oder Clipboard.
    struct Access {
        var pasteboard: NSPasteboard = .general
        var trusted: () -> Bool = { AXIsProcessTrusted() }
        var frontmost: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
        var read: (String, AXUIElement, TimeInterval) -> CFTypeRef? = attribute
        var sendPaste: () -> Void = postCmdV
    }

    struct Target {
        fileprivate let application: NSRunningApplication
        fileprivate let identity: PasteTargetPolicy.ApplicationIdentity
        fileprivate let window: AXUIElement?
        fileprivate let field: AXUIElement?
        fileprivate let fieldNotExposed: Bool
    }

    /// Liest nur Zielidentitäten, niemals den Inhalt eines fremden Textfelds.
    /// Eine hängende Ziel-App darf den Aufnahmebeginn nicht lange blockieren.
    static func captureTarget(access: Access = Access()) -> Target? {
        captureTarget(access: access, deadline: ProcessInfo.processInfo.systemUptime + 0.25)
    }

    private static func captureTarget(access: Access, deadline: TimeInterval) -> Target? {
        guard access.trusted(),
              let application = access.frontmost(),
              let identity = identity(of: application) else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        let window = element(kAXFocusedWindowAttribute, of: app, deadline: deadline, access: access)
        var field = element(kAXFocusedUIElementAttribute, of: app, deadline: deadline, access: access)
        let fieldNotExposed = field == nil
        if let candidate = field {
            let role = access.read(kAXRoleAttribute, candidate, deadline) as? String
            let supportedRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
            let fieldWindow = element(kAXWindowAttribute, of: candidate, deadline: deadline, access: access)
            if !supportedRoles.contains(role ?? "") || compare(window, fieldWindow) != .same {
                field = nil
            }
        }
        return Target(application: application, identity: identity, window: window, field: field, fieldNotExposed: fieldNotExposed)
    }

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
    enum Outcome: Equatable {
        /// Text wurde per synthetischem ⌘V eingefügt.
        case pasted
        /// Bildschirmfreigabe ist vorn: NICHT getippt — der Text liegt in der
        /// Zwischenablage und wandert über den geteilten Sync zum entfernten Mac;
        /// dort muss der Nutzer selbst ⌘V drücken. (Synthetische ⌘-Events werden
        /// von der Bildschirmfreigabe nicht als Modifier weitergereicht — am
        /// anderen Ende kam nur ein nacktes "v" an; real getestet mit echten
        /// ⌘-Down/-Up-Events, half nicht.)
        case clipboardOnlyScreenSharing
        /// Ziel gewechselt oder nicht eindeutig erkennbar: nur kopieren.
        case clipboardOnlyTargetChanged
        case clipboardOnlyTargetUnavailable
        /// Bedienungshilfen-Berechtigung fehlt; Text liegt in der Zwischenablage.
        case noPermission
        /// Eine neuere Kopieraktion hat Vorrang; das Diktat liegt dort nicht mehr bereit.
        case clipboardChanged
    }

    /// Fügt Text im unveränderten Ziel ein. Bei fehlender Zuordnung oder einem
    /// Zielwechsel bleibt der Text zum manuellen Einfügen in der Zwischenablage.
    @discardableResult
    static func paste(_ text: String, target: Target?, access: Access = Access()) -> Outcome {
        let pasteboard = access.pasteboard

        // Alle Items und Typen tief kopieren. Bilder, Dateien und Rich Text dürfen
        // durch ein Diktat ebenso wenig verlorengehen wie einfacher Text.
        let previous = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownChangeCount = pasteboard.changeCount

        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        let permission = access.trusted()
        let frontmost = access.frontmost()
        let screenSharing = screenSharingBundleIDs.contains(frontmost?.bundleIdentifier ?? "")
        let current = permission && !screenSharing ? captureTarget(access: access, deadline: deadline) : nil
        let original = target.flatMap { $0.application.isTerminated ? nil : $0.identity }
        let decision = PasteTargetPolicy.decide(
            originalApplication: original,
            currentApplication: current?.identity ?? identity(of: frontmost),
            window: compare(target?.window, current?.window),
            field: compareFields(target, current),
            accessibilityGranted: permission,
            screenSharingActive: screenSharing
        )
        guard pasteboard.changeCount == ownChangeCount else { return .clipboardChanged }
        switch decision {
        case .noPermission:
            return .noPermission
        case .clipboardOnlyScreenSharing:
            // Bildschirmfreigabe vorn: bewusst NICHT tippen. Der geteilte
            // Zwischenablage-Sync bringt den Text auf den entfernten Mac, das
            // ECHTE ⌘V des Nutzers dort funktioniert zuverlässig. Deshalb auch
            // KEIN Restore der alten Zwischenablage — das würde den Text vor dem
            // manuellen Einfügen wieder wegsyncen.
            return .clipboardOnlyScreenSharing
        case .clipboardOnlyTargetChanged:
            return .clipboardOnlyTargetChanged
        case .clipboardOnlyTargetUnavailable:
            return .clipboardOnlyTargetUnavailable
        case .paste:
            break
        }

        // Rollen-/Fenster-Metadaten können veralten, während AX auf die Ziel-App
        // wartet. Danach nur die tatsächlichen Fokusidentitäten erneut lesen.
        guard let target else { return .clipboardOnlyTargetUnavailable }
        let app = AXUIElementCreateApplication(target.identity.processIdentifier)
        let window = element(kAXFocusedWindowAttribute, of: app, deadline: deadline, access: access)
        let field = element(kAXFocusedUIElementAttribute, of: app, deadline: deadline, access: access)
        guard pasteboard.changeCount == ownChangeCount else { return .clipboardChanged }
        guard identity(of: access.frontmost()) == original else {
            return .clipboardOnlyTargetChanged
        }
        if compare(target.window, window) == .different || compare(target.field, field) == .different {
            return .clipboardOnlyTargetChanged
        }
        guard access.trusted(), compare(target.window, window) == .same,
              (compare(target.field, field) == .same || (target.fieldNotExposed && field == nil)),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return .clipboardOnlyTargetUnavailable
        }
        guard pasteboard.changeCount == ownChangeCount else { return .clipboardChanged }

        access.sendPaste()

        // Zwischenablage nach kurzer Zeit wiederherstellen — aber nur, wenn sie
        // noch unseren Text enthält. Eine neue Kopieraktion hat Vorrang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            previous.restore(to: pasteboard, ifChangeCountIs: ownChangeCount)
        }
        return .pasted
    }

    private static func identity(of application: NSRunningApplication?) -> PasteTargetPolicy.ApplicationIdentity? {
        guard let application, let bundleIdentifier = application.bundleIdentifier else { return nil }
        return .init(processIdentifier: application.processIdentifier, bundleIdentifier: bundleIdentifier)
    }

    // Einige Apps liefern ein Fenster, aber grundsätzlich kein AX-Fokusfeld.
    // Nur wenn beide Erfassungen so ausfallen, genügt dasselbe Fenster.
    // Ein einmal erkanntes Feld darf dagegen niemals still verloren gehen.
    private static func compareFields(_ original: Target?, _ current: Target?) -> PasteTargetPolicy.ElementMatch {
        if original?.fieldNotExposed == true, current?.fieldNotExposed == true {
            return .notExposed
        }
        return compare(original?.field, current?.field)
    }

    private static func compare(_ original: AXUIElement?, _ current: AXUIElement?) -> PasteTargetPolicy.ElementMatch {
        guard let original, let current else { return .unavailable }
        return CFEqual(original, current) ? .same : .different
    }

    private static func attribute(_ name: String, of element: AXUIElement, deadline: TimeInterval) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ name: String, of parent: AXUIElement, deadline: TimeInterval, access: Access) -> AXUIElement? {
        guard ProcessInfo.processInfo.systemUptime < deadline,
              let value = access.read(name, parent, deadline),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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
