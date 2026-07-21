import AppKit
import Sparkle
import StillePostCore

/// Verdrahtet alle Bausteine: Menüleisten-Symbol, Hotkey, Overlay, Sounds,
/// Diktier-Maschine, Verlaufsfenster.
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Sparkle verwaltet Suche, Download, Signaturprüfung, Austausch der App und
    /// Neustart. Als langlebiges Feld bleibt der Controller während der gesamten
    /// App-Laufzeit erhalten; mehr als eine Instanz darf es nicht geben.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var config = Config.load()
    private var engine: DictationEngine!
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyManager!
    private var overlay: OverlayController!
    private var historyWindow: HistoryWindowController!
    private var settingsWindow: SettingsWindowController!
    /// Pinnt das primäre Bereinigungs-Modell jede Minute neu — läuft nur im Modus
    /// "dauerhaft geladen" (siehe buildComponents); bei befristetem keep_alive nil.
    private var warmUpTimer: Timer?
    /// Fragt beim Start nach dem Whisper-Modell, falls keines da ist. Als Feld
    /// gehalten, damit der laufende Download nicht mitsamt Controller wegoptimiert wird.
    private let modelDownload = ModelDownloadController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Einzelinstanz-Schutz: Läuft schon eine Stille Post, beendet sich die neue
        // sofort. Zwei Instanzen würden sonst beide aufnehmen und beide einfügen —
        // der Text stünde doppelt im Ziel.
        if ProcessInfo.processInfo.environment["STILLEPOST_ALLOW_MULTIPLE"] == nil,
           let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        // Menüleisten-App ohne Dock-Symbol (LSUIElement steht zusätzlich im Info.plist
        // des App-Bundles; .accessory deckt den `swift run`-Entwicklungsfall ab).
        NSApp.setActivationPolicy(.accessory)

        settingsWindow = SettingsWindowController(
            onApply: { [weak self] newConfig in
                self?.applySettings(newConfig)
            },
            onHotkeyRecording: { [weak self] recording in
                self?.suspendHotkey(recording)
            }
        )

        setupStatusItem()

        // Headless-GUI-Testweg für das echte Statusmenü. Erst im nächsten Runloop
        // öffnen, damit AppKit das Menüleisten-Element vollständig registriert hat.
        if ProcessInfo.processInfo.environment["STILLEPOST_OPEN_MENU"] != nil {
            DispatchQueue.main.async { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
        buildComponents()

        // Bedienungshilfen-Berechtigung früh anstoßen (System-Dialog), damit das
        // erste Diktat nicht daran scheitert. Für automatisierte Tests abschaltbar,
        // weil der System-Dialog dort nur stören würde.
        if ProcessInfo.processInfo.environment["STILLEPOST_NO_AX_PROMPT"] == nil {
            _ = PasteService.ensureAccessibilityPermission()
        }

        // Ohne Modell kann die App nichts — deshalb gleich beim Start fragen und
        // nicht erst beim ersten Diktat scheitern lassen. Fragt nur, wenn wirklich
        // etwas fehlt (oder das Modell nur geliehen ist).
        modelDownload.offerIfNeeded(whisper: config.whisper) { [weak self] in
            // Nach dem Laden die Bausteine neu aufsetzen, damit der whisper-server
            // mit dem frischen Modell startet.
            self?.buildComponents()
        }

        // Für automatisierte GUI-Checks (headless-Testweg): Einstellungsfenster
        // sofort öffnen, ohne dass jemand durchs Menü klicken muss.
        if ProcessInfo.processInfo.environment["STILLEPOST_OPEN_SETTINGS"] != nil {
            settingsWindow.show()
        }
        // Isolierter Screenshot-/GUI-Testweg fürs Verlaufsfenster. Zusammen mit
        // STILLEPOST_APP_SUPPORT liest er ausschließlich künstliche Testeinträge.
        if ProcessInfo.processInfo.environment["STILLEPOST_OPEN_HISTORY"] != nil {
            historyWindow.show()
        }
        // Ebenfalls für GUI-Checks: Overlay in einem bestimmten Zustand zeigen
        // (das Overlay erscheint sonst nur mitten in einem echten Diktat).
        switch ProcessInfo.processInfo.environment["STILLEPOST_OVERLAY_PREVIEW"] {
        case "processing-fallback":
            overlay.show(.processing(detail: L10n.format(
                "app.cleanup_fallback",
                "qwen3.5:9b @ http://127.0.0.1:11434"
            )))
        case "success-raw":
            overlay.show(.success(note: L10n.text("app.raw_fallback_note")))
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

        registerHotkey()

        // Klick aufs Overlay stoppt ebenfalls.
        overlay.onClickStop = { [weak self] in
            self?.engine.toggle()
        }
        overlay.levelProvider = { [weak self] in
            guard let self else { return (-120, 0) }
            return (self.engine.currentLevelDb, self.engine.recordingDuration)
        }

        // Bereinigungs-Modell einmal beim Start vorwärmen, damit schon das erste
        // Diktat ohne Kaltstart auskommt.
        engine.keepCleanupModelWarm()
        warmUpTimer?.invalidate()
        warmUpTimer = nil

        // Jede Minute NEU anpinnen darf die App nur im Modus "dauerhaft geladen":
        // Der Tick (ein Ping + ein leerer Generate-Request, <1 s) übersteht
        // Ollama-Neustarts und fremde keep_alive-Resets. Bei einer BEFRISTETEN Frist
        // wäre derselbe Tick fatal — er würde die Uhr jede Minute zurücksetzen, das
        // Modell entlüde also nie, und die Einstellung wäre wirkungslos.
        //
        // Ohne diesen Timer bleibt das Vorwärmen beim Aufnahme-Start die Absicherung
        // gegen Kaltstarts (DictationEngine.start()): Es lädt das Modell, während man
        // noch spricht, und schiebt die Frist bei jedem Diktat neu an.
        guard CleanupService.pinsForever(config.cleanup.keepAlive) else { return }
        warmUpTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.engine.keepCleanupModelWarm()
        }
    }

    /// Meldet den globalen Hotkey an: Aufnahme ein/aus.
    ///
    /// Wichtig: Den alten Manager VOR dem Erzeugen des neuen freigeben. Swift wertet
    /// bei `hotkey = HotkeyManager(...)` zuerst die rechte Seite aus; Carbon sähe dann
    /// kurz zwei identische globale Hotkeys und lehnt den neuen ab. Anschließend würde
    /// deinit den alten abmelden — übrig bliebe gar keiner.
    private func registerHotkey() {
        hotkey = nil
        do {
            hotkey = try HotkeyManager(config: config.hotkey) { [weak self] in
                self?.engine.toggle()
            }
        } catch let error as HotkeyManager.RegistrationError {
            overlay.show(.failure(L10n.format(
                "app.hotkey_registration_failed",
                HotkeyManager.describe(config.hotkey),
                error.status
            )))
        } catch {
            overlay.show(.failure(L10n.format(
                "app.hotkey_registration_failed",
                HotkeyManager.describe(config.hotkey),
                -1
            )))
        }
    }

    /// Meldet den globalen Hotkey vorübergehend ab, solange der Einstellungsdialog
    /// eine neue Kombination aufnimmt. Ohne das würde Carbon den bisherigen Hotkey
    /// abfangen: Wer ⌘⌥D aufnehmen will, startet sonst ein Diktat, statt die
    /// Kombination zu setzen. Danach wieder anmelden — mit der GESPEICHERTEN Config,
    /// denn der Dialog arbeitet auf einer Kopie, die erst „Speichern“ übernimmt.
    private func suspendHotkey(_ suspended: Bool) {
        if suspended {
            hotkey = nil
        } else {
            registerHotkey()
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
            overlay.show(.failure(L10n.format("app.settings_save_failed", error.localizedDescription)))
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
        let toggleItem = NSMenuItem(title: L10n.format(
                                        "menu.toggle_dictation",
                                        HotkeyManager.describe(config.hotkey)
                                    ),
                                    action: #selector(toggleDictation), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let cancelItem = NSMenuItem(title: L10n.text("menu.cancel_recording"),
                                    action: #selector(cancelDictation), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: L10n.text("menu.history"),
                                     action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)
        let settingsItem = NSMenuItem(title: L10n.text("menu.settings"),
                                      action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let configItem = NSMenuItem(title: L10n.text("menu.open_config"),
                                    action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())
        // Sparkle selbst ist Target des Eintrags. Dadurch validiert es den Menüpunkt
        // auch während einer laufenden Suche oder Installation korrekt.
        let updateItem = NSMenuItem(
            title: L10n.text("menu.check_updates"),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.text("menu.quit"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func updateStatusIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }
        let (symbol, description): (String, String)
        switch state {
        case .idle: (symbol, description) = ("mic", L10n.text("status.ready"))
        case .starting: (symbol, description) = ("mic.badge.plus", L10n.text("status.starting"))
        case .recording: (symbol, description) = ("record.circle.fill", L10n.text("status.recording"))
        case .processing: (symbol, description) = ("waveform", L10n.text("status.transcribing"))
        case .error: (symbol, description) = ("exclamationmark.triangle.fill", L10n.text("status.error"))
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
        // Der Startton wird vollständig vor dem Öffnen des Mikrofons abgespielt.
        // Gerade das iPhone als Continuity-Mikrofon hört den Mac-Lautsprecher sehr
        // klar; der Ton darf deshalb nicht Teil des Whisper-Segments werden.
        engine.onBeforeRecordingStart = { [weak self] in
            await self?.playSoundAndWait(custom: "dictation-start", fallback: "Pop")
        }
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.updateStatusIcon(for: state)
            switch state {
            case .recording:
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
                    ? L10n.text("app.raw_fallback_note") : nil
                switch outcome {
                case .pasted:
                    self.overlay.show(.success(note: note))
                case .clipboardOnlyScreenSharing:
                    // Bildschirmfreigabe: Wir tippen bewusst nicht (käme drüben als
                    // nacktes "v" an) — der Sync trägt den Text rüber, der Nutzer
                    // fügt am entfernten Mac selbst ein.
                    self.overlay.show(.success(note: L10n.text("app.screen_sharing_note")))
                case .noPermission:
                    // Ohne Bedienungshilfen-Recht liegt der Text in der Zwischenablage.
                    self.overlay.show(.failure(L10n.text("app.paste_permission_missing")))
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
            self?.overlay.show(.processing(detail: L10n.format("app.cleanup_fallback", label)))
        }
        // Direktanfrage an den primären Endpoint ist gescheitert — es läuft sofort
        // ein zweiter Versuch über eine frische Verbindung.
        engine.onCleanupPrimaryRetry = { [weak self] in
            self?.overlay.show(.processing(detail: L10n.text("app.cleanup_primary_retry")))
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
        resolvedSound(custom: custom, fallback: fallback)?.play()
    }

    /// Spielt das Startsignal und kehrt erst nach dessen Ende zurück. `NSSound.play`
    /// selbst ist nicht blockierend; ohne dieses Warten würde die unmittelbar danach
    /// gestartete Aufnahme den restlichen Klang weiterhin mitschneiden.
    private func playSoundAndWait(custom: String?, fallback: String) async {
        guard config.ui.sounds,
              let sound = resolvedSound(custom: custom, fallback: fallback),
              sound.play() else { return }
        let duration = max(0, sound.duration) + 0.05
        guard duration > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }

    private func resolvedSound(custom: String?, fallback: String) -> NSSound? {
        if let custom {
            if let cached = soundCache[custom] {
                return cached
            }
            if let url = Bundle.main.resourceURL?
                .appendingPathComponent("sounds/\(custom).wav"),
               let sound = NSSound(contentsOf: url, byReference: true) {
                soundCache[custom] = sound
                return sound
            }
        }
        return NSSound(named: fallback)
    }
}
