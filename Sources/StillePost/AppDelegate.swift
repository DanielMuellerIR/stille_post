import AppKit
import Sparkle
import StillePostCore

/// Verdrahtet alle Bausteine: Menüleisten-Symbol, Hotkey, Overlay, Sounds,
/// Diktier-Maschine, Verlaufsfenster.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

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
    private var lastResultHotkey: HotkeyManager?
    private var isCapturingHotkey = false
    private var overlay: OverlayController!
    private var historyWindow: HistoryWindowController!
    private var pasteTarget: PasteService.Target?
    private let resultPreview = ResultPreviewController()
    private var resultMemory = TransientResultStore()
    private var settingsWindow: SettingsWindowController!
    /// Netzwerkzugang für eigene Geräte im Heimnetz; nil = ausgeschaltet.
    private var bridge: BridgeServer?
    private var bridgeTransition: Task<Void, Never>?
    private var bridgeGeneration = 0
    /// Protokoll der Brücke, das einen Neustart überlebt: `bridge.log` neben
    /// `config.json`. Absichtlich unabhängig vom Server-Objekt, damit auch ein
    /// fehlgeschlagener Start hineinschreiben kann.
    private let bridgeLog = BridgeLogFile()
    /// Pinnt das primäre Bereinigungs-Modell jede Minute neu — läuft nur im Modus
    /// "dauerhaft geladen" (siehe buildComponents); bei befristetem keep_alive nil.
    private var warmUpTimer: Timer?
    private var temporaryPrivateHistory = false
    private var historyMaintenanceTimer: Timer?
    private var historyMaintenanceTask: Task<Void, Never>?
    private var historyGeneration: UInt64 = 0
    /// Fragt beim Start nach dem Whisper-Modell, falls keines da ist. Als Feld
    /// gehalten, damit der laufende Download nicht mitsamt Controller wegoptimiert wird.
    private let modelDownload = ModelDownloadController()

    private func setupEditingMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(NSMenuItem(title: L10n.text("menu.quit"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let item = NSMenuItem(title: L10n.text("menu.edit"), action: nil, keyEquivalent: "")
        let edit = NSMenu(title: item.title)
        for (key, selector, equivalent) in [
            ("undo", "undo:", "z"), ("redo", "redo:", "z"),
            ("cut", "cut:", "x"), ("copy", "copy:", "c"),
            ("paste", "paste:", "v"), ("select_all", "selectAll:", "a")
        ] {
            let command = NSMenuItem(title: L10n.text("menu." + key),
                                     action: NSSelectorFromString(selector), keyEquivalent: equivalent)
            if key == "redo" { command.keyEquivalentModifierMask = [.command, .shift] }
            edit.addItem(command)
        }
        item.submenu = edit
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

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
        setupEditingMenu()

        settingsWindow = SettingsWindowController(
            onApply: { [weak self] newConfig in
                self?.applySettings(newConfig)
            },
            onHotkeyRecording: { [weak self] recording in
                self?.setHotkeyCaptureActive(recording)
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
                "gemma4:e4b-it-qat @ http://127.0.0.1:11434"
            )))
        case "success-raw":
            overlay.show(.success(note: L10n.text("app.raw_fallback_note")))
        case "clipboard-target-changed":
            overlay.show(.clipboard(note: L10n.text("app.paste_target_changed")))
        case "clipboard-target-unavailable":
            overlay.show(.clipboard(note: L10n.text("app.paste_target_unavailable")))
        case .some, .none:
            break
        }
        // Künstlicher Ergebnisweg für Bundle-Abnahmen, nur mit isolierten Daten.
        // Keine Aufnahme, Bereinigung oder Speicherung persönlicher Testtexte.
        let environment = ProcessInfo.processInfo.environment
        if environment["STILLEPOST_APP_SUPPORT"] != nil,
           environment["STILLEPOST_CONFIG"] != nil,
           let test = environment["STILLEPOST_RESULT_TEST"],
           ["seed", "success", "raw", "empty", "failed", "long"].contains(test) {
            let synthetic = "Dies ist ein künstlicher Ergebnistext. Zahlen: 128 Euro."
            let text = test == "long"
                ? (1...80).map { "Absatz \($0): \(synthetic)" }.joined(separator: "\n\n")
                : synthetic
            if environment["STILLEPOST_RESULT_TEST_PREVIOUS"] == "1" {
                resultMemory.accept(text: "Zuvor bestätigter Testtext.", rawFallback: false)
            }
            if test == "seed" {
                resultMemory.accept(text: text, rawFallback: false)
            } else {
                engine.onStateChange?(.starting)
                engine.onStateChange?(.idle)
                let failed = test == "failed"
                let delivered = test == "empty" || failed ? "" : text
                let entry = HistoryStore.Entry(rawText: delivered, cleanText: delivered,
                    status: failed ? "failed" : "ok", durationSec: 1,
                    cleanupFellBack: test == "raw")
                engine.onResult?(DictationResult(text: delivered, entry: entry))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge?.stop()
        historyMaintenanceTimer?.invalidate()
        historyMaintenanceTask?.cancel()
        engine.shutdown()
    }

    // MARK: - Bausteine aufbauen / Einstellungen anwenden

    /// Baut Engine, Overlay, Verlaufsfenster und Hotkey aus der aktuellen Config auf.
    /// Läuft beim Start und nach jedem Speichern der Einstellungen.
    private func buildComponents() {
        pasteTarget = nil
        var engineConfig = config
        engineConfig.history = effectiveHistoryPolicy
        engine = DictationEngine(config: engineConfig)
        overlay = OverlayController(config: config.ui)
        historyWindow = HistoryWindowController(engine: engine)
        setupEngineCallbacks()
        startHistoryMaintenance()

        registerHotkey()

        // Klick aufs Overlay stoppt ebenfalls.
        overlay.onClickStop = { [weak self] in
            self?.engine.toggle()
        }
        overlay.levelProvider = { [weak self] in
            guard let self else { return (-120, 0) }
            return (self.engine.currentLevelDb, self.engine.recordingDuration)
        }

        startBridgeIfEnabled()

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

    /// Öffnet den Netzwerkzugang für eigene Geräte im Heimnetz, wenn er in den
    /// Einstellungen eingeschaltet ist. Fehler (Port belegt, kein Token) werden
    /// gezeigt statt verschluckt: Ein stillschweigend nicht laufender Zugang wäre
    /// später als „das iPhone kommt nicht durch“ viel schwerer zu finden.
    private func startBridgeIfEnabled() {
        bridgeGeneration += 1
        let generation = bridgeGeneration
        let previous = bridgeTransition
        bridgeTransition = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.bridgeGeneration == generation else { return }
            let old = self.bridge
            self.bridge = nil
            if let old {
                await withCheckedContinuation { continuation in
                    old.stop { continuation.resume() }
                }
            }
            guard self.bridgeGeneration == generation else { return }
            if self.config.bridge.enabled { self.launchBridge() }
            self.bridgeTransition = nil
        }
    }

    private func launchBridge() {
        let server = BridgeServer(config: config)
        // Zusätzlich zur Datei: stderr bleibt für `swift run` und Diagnoseläufe.
        // Bei der aus dem Finder gestarteten App landet stderr nirgends — deshalb
        // ist die Datei neben config.json der eigentliche Ort zum Nachsehen.
        let logFile = bridgeLog
        server.onLog = { message in
            FileHandle.standardError.write(Data("StillePost bridge: \(message)\n".utf8))
            logFile.append(message)
        }
        bridge = server
        server.start { [weak self, weak server] result in
            Task { @MainActor in
                guard let self, let server, self.bridge === server else { return }
                if case .failure(let error) = result {
                    self.bridge = nil
                    let message = L10n.format("app.bridge_start_failed", error.localizedDescription)
                    logFile.append(message)
                    self.overlay.show(.failure(message))
                }
            }
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
        lastResultHotkey = nil
        func register(_ combination: Config.Hotkey, identifier: UInt32,
                      action: @escaping () -> Void) -> HotkeyManager? {
            do {
                return try HotkeyManager(config: combination, identifier: identifier, onPress: action)
            } catch {
                let status = (error as? HotkeyManager.RegistrationError)?.status ?? -1
                overlay.show(.failure(L10n.format("app.hotkey_registration_failed",
                    HotkeyManager.describe(combination), status)))
                return nil
            }
        }
        let dictationCombination = config.hotkey
        let recallCombination = config.lastResultHotkey
        hotkey = register(dictationCombination, identifier: 1) { [weak self] in
            guard let self else { return }
            self.routeHotkey(dictationCombination) { self.engine.toggle() }
        }
        lastResultHotkey = register(recallCombination, identifier: 2) { [weak self] in
            guard let self else { return }
            self.routeHotkey(recallCombination) { self.showLastResult() }
        }
    }

    /// Bereits registrierte Kombinationen kommen als Carbon-Ereignis an. Während
    /// der Aufnahme gehen sie an den Recorder; nach einem Abmelden könnte das
    /// System sie abfangen, bevor der lokale NSEvent-Monitor sie erhält.
    private func setHotkeyCaptureActive(_ active: Bool) {
        isCapturingHotkey = active
    }

    private func routeHotkey(_ combination: Config.Hotkey, perform action: () -> Void) {
        if isCapturingHotkey {
            NotificationCenter.default.post(name: HotkeyManager.captureNotification, object: combination)
        } else {
            action()
        }
    }

    private var effectiveHistoryPolicy: Config.History {
        var policy = config.history
        if temporaryPrivateHistory { policy.storeText = false }
        return policy
    }

    @objc private func togglePrivateHistory() {
        guard config.history.storeText else { return }
        temporaryPrivateHistory.toggle()
        let environment = ProcessInfo.processInfo.environment
        if environment["STILLEPOST_HISTORY_TRACE"] == "1",
           environment["STILLEPOST_CONFIG"] != nil, environment["STILLEPOST_APP_SUPPORT"] != nil {
            FileHandle.standardError.write(Data("history-policy: storesText=\(effectiveHistoryPolicy.storeText)\n".utf8))
        }
        engine.configureHistory(effectiveHistoryPolicy)
        updatePrivateHistoryMenu()
    }

    private func updatePrivateHistoryMenu() {
        let item = statusItem.menu?.items.first { $0.action == #selector(togglePrivateHistory) }
        item?.state = effectiveHistoryPolicy.storeText ? .off : .on
        item?.isEnabled = config.history.storeText
    }

    private func startHistoryMaintenance() {
        historyGeneration &+= 1
        historyMaintenanceTask?.cancel()
        historyMaintenanceTask = nil
        historyMaintenanceTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.runHistoryMaintenance() }
        RunLoop.main.add(timer, forMode: .common)
        historyMaintenanceTimer = timer
        runHistoryMaintenance()
    }

    private func runHistoryMaintenance() {
        guard historyMaintenanceTask == nil else { return }
        let history = engine.history
        let generation = historyGeneration
        historyMaintenanceTask = Task { @MainActor [weak self] in
            defer {
                if self?.historyGeneration == generation { self?.historyMaintenanceTask = nil }
            }
            do { try await history.applyRetentionAsync() }
            catch {
                guard let self, self.historyGeneration == generation else { return }
                let message = L10n.format("history.retention_error", error.localizedDescription)
                self.historyWindow.reportError(message)
                if self.canRecallResult { self.overlay.show(.failure(message)) }
            }
        }
    }

    /// Reine Verlaufsregeln gelten erst für neue Aufträge und beenden keine
    /// laufende Aufnahme. Andere Einstellungen behalten ihren Neuaufbau.
    private func applySettings(_ newConfig: Config) {
        do {
            try newConfig.save()
        } catch {
            NSSound(named: "Basso")?.play()
            overlay.show(.failure(L10n.format("app.settings_save_failed", error.localizedDescription)))
            return
        }
        var historyOnly = config
        historyOnly.history = newConfig.history
        if historyOnly == newConfig {
            config = newConfig
            engine.configureHistory(effectiveHistoryPolicy)
            updatePrivateHistoryMenu()
            return
        }
        overlay.hide()
        resultPreview.dismiss()
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
        let lastResultItem = NSMenuItem(title: L10n.format("menu.last_result",
            HotkeyManager.describe(config.lastResultHotkey)), action: #selector(showLastResult), keyEquivalent: "")
        lastResultItem.target = self
        menu.addItem(lastResultItem)
        let privateItem = NSMenuItem(title: L10n.text("menu.private_history"),
            action: #selector(togglePrivateHistory), keyEquivalent: "")
        privateItem.target = self
        privateItem.state = effectiveHistoryPolicy.storeText ? .off : .on
        privateItem.toolTip = L10n.text("menu.private_history.help")
        menu.addItem(privateItem)
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
        // Ruhesymbol bewusst nicht das nackte "mic": Das Kontrollzentrum zeigt bei
        // Mikrofon-Nutzung (z. B. Videocall) ein fast identisches Mikrofon in der
        // Menüleiste, was wie ein doppeltes Stille-Post-Icon wirkt.
        case .idle: (symbol, description) = ("waveform.and.mic", L10n.text("status.ready"))
        case .starting: (symbol, description) = ("mic.badge.plus", L10n.text("status.starting"))
        case .recording: (symbol, description) = ("record.circle.fill", L10n.text("status.recording"))
        // Eingekreist statt "waveform", damit Verarbeitung nicht wie das neue
        // Ruhesymbol (waveform.and.mic) aussieht.
        case .processing: (symbol, description) = ("waveform.circle", L10n.text("status.transcribing"))
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
            case .starting:
                self.resultPreview.dismiss()
                self.pasteTarget = PasteService.captureTarget()
            case .recording:
                self.overlay.show(.recording)
            case .processing:
                // Tieferer Whoosh/Ding: deutlich ANDERES "Aufnahme beendet"-Signal.
                self.playSound(custom: "dictation-stop", fallback: "Bottle")
                self.overlay.show(.processing())
            case .error(let message):
                self.playSound(custom: nil, fallback: "Basso")  // Fehler-Sound
                self.overlay.show(.failure(message))
            case .idle:
                break
            }
        }

        engine.onResult = { [weak self] result in
            guard let self else { return }
            defer { self.pasteTarget = nil }
            if let entry = result.entry,
               let usable = TransientResultStore.Result(text: result.text,
                    rawFallback: entry.cleanupFellBack == true, failed: entry.isFailed) {
                if self.config.ui.previewBeforePaste {
                    self.overlay.hide()
                    self.showPreview(usable, target: self.pasteTarget)
                } else {
                    self.remember(usable)
                    self.insert(usable, target: self.pasteTarget)
                }
            } else if result.entry?.isFailed != true,
                      result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nur Stille aufgenommen.
                self.overlay.show(.silence)
            }
            // Fehlerfall zeigt schon onStateChange(.error) an.
        }

        engine.onPrivateRetryResult = { [weak self] entry in
            guard let self, let result = TransientResultStore.Result(text: entry.cleanText,
                rawFallback: entry.cleanupFellBack == true) else { return }
            self.showPreview(result, target: PasteService.captureTarget(), focus: self.canRecallResult, floating: false)
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

    private var canRecallResult: Bool {
        if case .idle = engine.state { return true }
        if case .error = engine.state { return true }
        return false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePrivateHistory) { return config.history.storeText }
        return menuItem.action != #selector(showLastResult) ||
            ((resultMemory.last != nil || resultPreview.isVisible) && canRecallResult)
    }

    @objc private func showLastResult() {
        guard canRecallResult else { return }
        if resultPreview.isVisible {
            resultPreview.focus()
            return
        }
        guard let result = resultMemory.last else {
            overlay.show(.failure(L10n.text("result.empty")))
            return
        }
        overlay.hide()
        showPreview(result, target: PasteService.captureTarget(), focus: true)
    }

    private func remember(_ result: TransientResultStore.Result) {
        resultMemory.accept(text: result.text, rawFallback: result.rawFallback)
    }

    private func showPreview(_ result: TransientResultStore.Result, target: PasteService.Target?, focus: Bool = false, floating: Bool = true) {
        resultPreview.show(result, focus: focus, floating: floating) { [weak self] action in
            guard let self else { return }
            switch action {
            case .discard: break
            case .copy:
                self.remember(result)
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(result.text, forType: .string)
                self.overlay.show(.clipboard(note: L10n.text("result.copied")))
            case .insert:
                self.remember(result)
                self.insert(result, target: target)
            }
        }
    }

    private func insert(_ result: TransientResultStore.Result, target: PasteService.Target?) {
        switch PasteService.paste(result.text, target: target) {
        case .pasted:
            overlay.show(.success(note: result.rawFallback ? L10n.text("app.raw_fallback_note") : nil))
        case .clipboardOnlyScreenSharing:
            overlay.show(.clipboard(note: L10n.text("app.screen_sharing_note")))
        case .clipboardOnlyTargetChanged:
            overlay.show(.clipboard(note: L10n.text("app.paste_target_changed")))
        case .clipboardOnlyTargetUnavailable:
            overlay.show(.clipboard(note: L10n.text("app.paste_target_unavailable")))
        case .noPermission:
            overlay.show(.failure(L10n.text("app.paste_permission_missing")))
        }
    }

    @objc private func toggleDictation() { engine.toggle() }
    @objc private func cancelDictation() {
        pasteTarget = nil
        resultPreview.dismiss()
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
