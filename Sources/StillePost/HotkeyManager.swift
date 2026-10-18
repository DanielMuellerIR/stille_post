import AppKit
import Carbon.HIToolbox
import StillePostCore

/// Registriert eine globale Tastenkombination über die Carbon-API
/// `RegisterEventHotKey`. Vorteil gegenüber Event-Taps: funktioniert OHNE
/// Bedienungshilfen-Berechtigung und ist über Jahrzehnte stabil.
final class HotkeyManager {
    static let captureNotification = Notification.Name("StillePost.hotkeyCaptured")

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private let onInterruption: () -> Void
    private let onHoldLimit: () -> Void
    private let identifier: UInt32
    private let keyCode: CGKeyCode
    private let requiredFlags: CGEventFlags
    private let maximumHoldDuration: TimeInterval
    private var readsKeyState = false
    private var isDown = false
    private var waitsForKeyUp = false
    private var pressedAt: TimeInterval = 0
    private var reachedLimit = false
    private var releaseTimer: Timer?
    private var interruptionObservers: [NSObjectProtocol] = []

    static var canReadKeyboardState: Bool {
        AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    var isCombinationHeld: Bool {
        CGEventSource.keyState(.combinedSessionState, key: keyCode)
            && CGEventSource.flagsState(.combinedSessionState).isSuperset(of: requiredFlags)
    }

    init(config: Config.Hotkey, identifier: UInt32 = 1,
         onRelease: @escaping () -> Void = {}, onInterruption: @escaping () -> Void = {},
         onHoldLimit: @escaping () -> Void = {},
         maximumHoldDuration: TimeInterval = DictationHotkeyState.maximumHoldDuration,
         onPress: @escaping () -> Void) throws {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onInterruption = onInterruption
        self.onHoldLimit = onHoldLimit
        self.identifier = identifier
        keyCode = CGKeyCode(clamping: config.keyCode)
        self.maximumHoldDuration = maximumHoldDuration
        var flags: CGEventFlags = []
        for name in config.modifiers {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        requiredFlags = flags
        guard config.isUsableGlobally, (0...127).contains(config.keyCode) else {
            throw RegistrationError.hotKey(OSStatus(paramErr))
        }

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

        // Handler für Drücken und Loslassen installieren. Der C-Callback bekommt
        // `self` als rohen Zeiger durchgereicht (übliches Carbon-Muster).
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotkeyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID) == noErr,
                  hotkeyID.signature == OSType(0x5350_4F53),
                  hotkeyID.id == manager.identifier else { return OSStatus(eventNotHandledErr) }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { [weak manager] in
                if pressed { manager?.pressed() } else { manager?.released() }
            }
            return noErr
        }, eventTypes.count, &eventTypes, selfPointer, &eventHandler)
        guard handlerStatus == noErr else {
            throw RegistrationError.eventHandler(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4F53) /* "SPOS" */, id: identifier)
        let registrationStatus = RegisterEventHotKey(
            UInt32(config.keyCode), modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registrationStatus == noErr else {
            // Ein fehlgeschlagener Initializer ruft deinit nicht zuverlässig für
            // teilweise aufgebaute Ressourcen auf. Den Handler deshalb hier lösen.
            if let eventHandler { RemoveEventHandler(eventHandler) }
            self.eventHandler = nil
            throw RegistrationError.hotKey(registrationStatus)
        }
        let center = NSWorkspace.shared.notificationCenter
        interruptionObservers = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                  NSWorkspace.sessionDidResignActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isDown else { return }
                self.onInterruption()
            }
        }
        // Eine bei Registrierung schon gehaltene Taste ist keine neue Betätigung.
        readsKeyState = Self.canReadKeyboardState
        waitsForKeyUp = readsKeyState && CGEventSource.keyState(.combinedSessionState, key: keyCode)
        if waitsForKeyUp { startReleaseTimer() }
    }

    private func pressed() {
        guard !isDown, !waitsForKeyUp else { return }
        readsKeyState = Self.canReadKeyboardState
        isDown = true
        reachedLimit = false
        pressedAt = ProcessInfo.processInfo.systemUptime
        onPress()
        startReleaseTimer()
    }

    private func startReleaseTimer() {
        guard releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkRelease() }
        releaseTimer = timer
        // Auch ein geöffnetes Menü darf Freigabe und Sicherheitsfrist nicht aufhalten.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func released() {
        let mainKeyDown = readsKeyState && CGEventSource.keyState(.combinedSessionState, key: keyCode)
        waitsForKeyUp = mainKeyDown
        if isDown {
            isDown = false
            onRelease()
        }
        if !waitsForKeyUp {
            releaseTimer?.invalidate()
            releaseTimer = nil
        }
    }

    private func checkRelease() {
        let keyDown = !readsKeyState || CGEventSource.keyState(.combinedSessionState, key: keyCode)
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !keyDown || !flags.isSuperset(of: requiredFlags) {
            released()
        } else if isDown && !reachedLimit && ProcessInfo.processInfo.systemUptime - pressedAt >= maximumHoldDuration {
            reachedLimit = true
            onHoldLimit()
        }
    }

    enum RegistrationError: Error {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var status: OSStatus {
            switch self {
            case .eventHandler(let status), .hotKey(let status): return status
            }
        }
    }

    deinit {
        releaseTimer?.invalidate()
        for observer in interruptionObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
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
