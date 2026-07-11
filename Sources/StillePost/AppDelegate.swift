import AppKit
import StillePostCore

/// Verdrahtet alle Bausteine: Menüleisten-Symbol, Hotkey, Overlay, Sounds,
/// Diktier-Maschine, Verlaufsfenster.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = Config.load()
    private var engine: DictationEngine!
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyManager!
    private var overlay: OverlayController!
    private var historyWindow: HistoryWindowController!
    private var settingsWindow: SettingsWindowController!
    /// Hält das primäre Bereinigungs-Modell dauerhaft geladen (siehe buildComponents).
    private var warmUpTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Einzelinstanz-Schutz: Läuft schon eine Stille Post, beendet sich die neue
        // sofort. Zwei Instanzen würden sonst beide aufnehmen und beide einfügen —
        // der Text stünde doppelt im Ziel.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        // Menüleisten-App ohne Dock-Symbol (LSUIElement steht zusätzlich im Info.plist
        // des App-Bundles; .accessory deckt den `swift run`-Entwicklungsfall ab).
        NSApp.setActivationPolicy(.accessory)

        settingsWindow = SettingsWindowController { [weak self] newConfig in
            self?.applySettings(newConfig)
        }

        setupStatusItem()
        buildComponents()

        // Bedienungshilfen-Berechtigung früh anstoßen (System-Dialog), damit das
        // erste Diktat nicht daran scheitert. Für automatisierte Tests abschaltbar,
        // weil der System-Dialog dort nur stören würde.
        if ProcessInfo.processInfo.environment["STILLEPOST_NO_AX_PROMPT"] == nil {
            _ = PasteService.ensureAccessibilityPermission()
        }

        // Für automatisierte GUI-Checks (headless-Testweg): Einstellungsfenster
        // sofort öffnen, ohne dass jemand durchs Menü klicken muss.
        if ProcessInfo.processInfo.environment["STILLEPOST_OPEN_SETTINGS"] != nil {
            settingsWindow.show()
        }
        // Ebenfalls für GUI-Checks: Overlay in einem bestimmten Zustand zeigen
        // (das Overlay erscheint sonst nur mitten in einem echten Diktat).
        switch ProcessInfo.processInfo.environment["STILLEPOST_OVERLAY_PREVIEW"] {
        case "processing-fallback":
            overlay.show(.processing(detail: "⚠️ Ausweichweg: qwen3.5:9b @ http://127.0.0.1:11434"))
        case "success-raw":
            overlay.show(.success(note: "⚠️ Unbereinigter Rohtext (Bereinigung fehlgeschlagen/verworfen)"))
        case .some, .none:
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    // MARK: - Bausteine aufbauen / Einstellungen anwenden

    /// Baut Engine, Overlay, Verlaufsfenster und Hotkey aus der aktuellen Config auf.
    /// Läuft beim Start und nach jedem Speichern der Einstellungen.
    private func buildComponents() {
        engine = DictationEngine(config: config)
        overlay = OverlayController(config: config.ui)
        historyWindow = HistoryWindowController(engine: engine)
        setupEngineCallbacks()

        // Globaler Hotkey: Aufnahme ein/aus. (Der alte HotkeyManager deregistriert
        // sich in seinem deinit selbst — einfaches Ersetzen reicht.)
        hotkey = HotkeyManager(config: config.hotkey) { [weak self] in
            self?.engine.toggle()
        }

        // Klick aufs Overlay stoppt ebenfalls.
        overlay.onClickStop = { [weak self] in
            self?.engine.toggle()
        }
        overlay.levelProvider = { [weak self] in
            guard let self else { return (-120, 0) }
            return (self.engine.currentLevelDb, self.engine.recordingDuration)
        }

        // Bereinigungs-Modell dauerhaft warmhalten: sofort beim Start und dann
        // jede Minute neu anpinnen (Kosten pro Tick: ein Ping + ein leerer
        // Generate-Request, <1 s). Übersteht Ollama-Neustarts und fremde
        // keep_alive-Resets — und weil die Kette durchfällt, ist bei einem
        // Ausfall des primären Rechners (WLAN-Aussetzer, unterwegs) das
        // Fallback-Modell binnen ~1 min vorgewärmt statt erst mitten im Diktat.
        engine.keepCleanupModelWarm()
        warmUpTimer?.invalidate()
        warmUpTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.engine.keepCleanupModelWarm()
        }
    }

    /// Übernimmt die im Einstellungsfenster gespeicherte Config: schreibt config.json
    /// und baut alle Bausteine neu auf. Eine laufende Aufnahme wird dabei abgebrochen;
    /// ein selbst gestarteter whisper-server wird beendet und beim nächsten Diktat mit
    /// den neuen Einstellungen frisch gestartet (kostet dort einmalig den Modell-Load —
    /// bewusst so, statt Sonderfälle für "hat sich Whisper geändert?" zu pflegen).
    private func applySettings(_ newConfig: Config) {
        do {
            try newConfig.save()
        } catch {
            NSSound(named: "Basso")?.play()
            overlay.show(.failure("Einstellungen konnten nicht gespeichert werden: \(error.localizedDescription)"))
            return
        }
        overlay.hide()
        historyWindow.close()
        engine.shutdown()
        config = newConfig
        buildComponents()
        // Menü neu beschriften (zeigt den ggf. geänderten Hotkey an).
        statusItem.menu = buildMenu()
    }

    // MARK: - Menüleiste

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(for: .idle)
        statusItem.menu = buildMenu()
    }

    /// Baut das Menüleisten-Menü (nach Einstellungs-Änderungen erneut aufgerufen,
    /// damit die Hotkey-Anzeige aktuell bleibt).
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: "Diktat starten/stoppen (\(HotkeyManager.describe(config.hotkey)))",
                                    action: #selector(toggleDictation), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let cancelItem = NSMenuItem(title: "Aufnahme abbrechen", action: #selector(cancelDictation), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "Verlauf …", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: "Einstellungen …", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let configItem = NSMenuItem(title: "Konfigurationsdatei öffnen", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Stille Post beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func updateStatusIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String)
        switch state {
        case .idle: (symbol, description) = ("mic", "Stille Post — bereit")
        case .starting: (symbol, description) = ("mic.badge.plus", "Stille Post — startet")
        case .recording: (symbol, description) = ("record.circle.fill", "Stille Post — AUFNAHME LÄUFT")
        case .processing: (symbol, description) = ("waveform", "Stille Post — transkribiert")
        case .error: (symbol, description) = ("exclamationmark.triangle.fill", "Stille Post — Fehler")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        // Aufnahme-Zustand zusätzlich einfärben (rot), damit auch die Menüleiste
        // unmissverständlich ist.
        if case .recording = state {
            image?.isTemplate = false
            button.contentTintColor = .systemRed
        } else {
            image?.isTemplate = true
            button.contentTintColor = nil
        }
        button.image = image
        button.toolTip = description
    }

    // MARK: - Engine-Callbacks (Zustand -> Oberfläche)

    private func setupEngineCallbacks() {
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.updateStatusIcon(for: state)
            switch state {
            case .recording:
                // Eigener "Blup" (generiert): deutliches "Aufnahme läuft"-Signal.
                self.playSound(custom: "dictation-start", fallback: "Pop")
                self.overlay.show(.recording)
            case .processing:
                // Tieferer Whoosh/Ding: deutlich ANDERES "Aufnahme beendet"-Signal.
                self.playSound(custom: "dictation-stop", fallback: "Bottle")
                self.overlay.show(.processing())
            case .error(let message):
                self.playSound(custom: nil, fallback: "Basso")  // Fehler-Sound
                self.overlay.show(.failure(message))
            case .idle, .starting:
                break
            }
        }

        engine.onResult = { [weak self] result in
            guard let self else { return }
            if let entry = result.entry, !entry.isFailed, !result.text.isEmpty {
                let outcome = PasteService.paste(result.text)
                // Transparenz: Wurde die LLM-Bereinigung verworfen (Rohtext benutzt),
                // soll man das SOFORT sehen — nicht erst später im Verlauf rätseln.
                let note = entry.cleanupFellBack == true
                    ? "⚠️ Unbereinigter Rohtext (Bereinigung fehlgeschlagen/verworfen)" : nil
                switch outcome {
                case .pasted:
                    self.overlay.show(.success(note: note))
                case .clipboardOnlyScreenSharing:
                    // Bildschirmfreigabe: Wir tippen bewusst nicht (käme drüben als
                    // nacktes "v" an) — der Sync trägt den Text rüber, der Nutzer
                    // fügt am entfernten Mac selbst ein.
                    self.overlay.show(.success(note: "⚠️ Bildschirmfreigabe: dort jetzt ⌘V drücken (Text ist in der Zwischenablage)"))
                case .noPermission:
                    // Ohne Bedienungshilfen-Recht liegt der Text in der Zwischenablage.
                    self.overlay.show(.failure("Kein Einfüge-Recht — Text liegt in der Zwischenablage (⌘V)"))
                }
            } else if result.entry == nil, result.text.isEmpty {
                // Nur Stille aufgenommen.
                self.overlay.show(.silence)
            }
            // Fehlerfall zeigt schon onStateChange(.error) an.
        }

        // Bereinigung weicht gerade auf einen Fallback-Endpoint aus: im Overlay
        // anzeigen, damit eine evtl. längere Wartezeit erklärbar ist.
        engine.onCleanupFallback = { [weak self] label in
            self?.overlay.show(.processing(detail: "⚠️ Ausweichweg: \(label)"))
        }
        // Direktanfrage an den primären Endpoint ist gescheitert — es läuft sofort
        // ein zweiter Versuch über eine frische Verbindung.
        engine.onCleanupPrimaryRetry = { [weak self] in
            self?.overlay.show(.processing(detail: "⚠️ Verbindungsproblem — zweiter Versuch …"))
        }
    }

    // MARK: - Menü-Aktionen

    @objc private func toggleDictation() { engine.toggle() }
    @objc private func cancelDictation() {
        engine.cancel()
        overlay.hide()
    }
    @objc private func showHistory() { historyWindow.show() }
    @objc private func showSettings() { settingsWindow.show() }
    @objc private func openConfig() {
        // Config-Datei existiert nach Config.load() immer.
        NSWorkspace.shared.open(Config.configFile)
    }

    /// Merkt sich geladene Sounds (NSSound jedes Mal neu von Platte laden knackst).
    private var soundCache: [String: NSSound] = [:]

    /// Spielt einen eigenen Sound aus dem App-Bundle (Contents/Resources/sounds/),
    /// oder — falls nicht vorhanden, z. B. beim Entwickeln mit `swift run` —
    /// den benannten macOS-Systemklang.
    private func playSound(custom: String?, fallback: String) {
        guard config.ui.sounds else { return }
        if let custom {
            if let cached = soundCache[custom] {
                cached.play()
                return
            }
            if let url = Bundle.main.resourceURL?
                .appendingPathComponent("sounds/\(custom).wav"),
               let sound = NSSound(contentsOf: url, byReference: true) {
                soundCache[custom] = sound
                sound.play()
                return
            }
        }
        NSSound(named: fallback)?.play()
    }
}
