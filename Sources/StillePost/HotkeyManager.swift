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

    /// Übersetzt die Zusatztasten eines ECHTEN Tastendrucks in unsere Config-Strings.
    /// Reihenfolge wie im Default (⌘⌥⌃⇧), damit describe() stabil dasselbe zeigt.
    static func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("cmd") }
        if flags.contains(.option) { names.append("opt") }
        if flags.contains(.control) { names.append("ctrl") }
        if flags.contains(.shift) { names.append("shift") }
        return names
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

    /// Name einer Taste fürs Anzeigen (die Registrierung nutzt weiter den Keycode).
    ///
    /// Zwei Stufen, weil Keycodes PHYSISCHE Tastenpositionen sind, keine Zeichen:
    ///  1. Tasten ohne Zeichen (Leertaste, Pfeile, F-Tasten) stehen in der Tabelle.
    ///  2. Alles andere wird über das AKTUELLE Tastaturlayout übersetzt. Sonst hieße
    ///     Keycode 6 immer "Z" — auf einer deutschen Tastatur liegt dort aber "Y".
    static func keyName(for keyCode: Int) -> String {
        let special: [Int: String] = [
            49: L10n.text("hotkey.space"), 36: "↩", 48: "⇥", 53: "⎋", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        ]
        if let name = special[keyCode] { return name }
        return layoutKeyName(for: keyCode) ?? "Keycode \(keyCode)"
    }

    /// Fragt das aktuell aktive Tastaturlayout, welches Zeichen auf dieser Taste liegt.
    /// Liefert nil, wenn das Layout nichts Darstellbares hergibt (z. B. reine
    /// Sondertasten oder ein Layout ohne Unicode-Daten, etwa bei manchen IMEs).
    private static func layoutKeyName(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return errSecParam }
            // kUCKeyActionDisplay + keine Modifier: liefert das Zeichen, das auf der
            // Taste steht — genau das, was man auf der Tastatur sieht.
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let name = String(utf16CodeUnits: characters, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return name.isEmpty ? nil : name
    }
}
