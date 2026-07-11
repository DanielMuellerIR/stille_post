import AppKit
import Carbon.HIToolbox
import StillePostCore

/// Registriert den globalen Hotkey (Aufnahme ein/aus) über die Carbon-API
/// `RegisterEventHotKey`. Vorteil gegenüber Event-Taps: funktioniert OHNE
/// Bedienungshilfen-Berechtigung und ist über Jahrzehnte stabil.
final class HotkeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void

    init(config: Config.Hotkey, onPress: @escaping () -> Void) {
        self.onPress = onPress

        // Modifier-Strings aus der Config in Carbon-Bitmaske übersetzen.
        var modifiers: UInt32 = 0
        for name in config.modifiers {
            switch name.lowercased() {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: break
            }
        }

        // Handler für "Hotkey wurde gedrückt" installieren. Der C-Callback bekommt
        // `self` als rohen Zeiger durchgereicht (übliches Carbon-Muster).
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onPress() }
            return noErr
        }, 1, &eventType, selfPointer, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4F53) /* "SPOS" */, id: 1)
        RegisterEventHotKey(UInt32(config.keyCode), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Menschenlesbare Beschreibung des Hotkeys (für Menü und Doku).
    static func describe(_ config: Config.Hotkey) -> String {
        var parts: [String] = []
        for name in config.modifiers {
            switch name.lowercased() {
            case "cmd", "command": parts.append("⌘")
            case "opt", "option", "alt": parts.append("⌥")
            case "ctrl", "control": parts.append("⌃")
            case "shift": parts.append("⇧")
            default: break
            }
        }
        parts.append(keyName(for: config.keyCode))
        return parts.joined()
    }

    /// Namen der wichtigsten Tasten (nur fürs Anzeigen; die Registrierung nutzt den Keycode).
    private static func keyName(for keyCode: Int) -> String {
        let names: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Leertaste",
            36: "↩", 48: "⇥", 53: "⎋", 50: "`",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        ]
        return names[keyCode] ?? "Keycode \(keyCode)"
    }
}
