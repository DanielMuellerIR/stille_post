import AppKit
import Sparkle
import StillePostCore

/// Verdrahtet alle Bausteine: Menüleisten-Symbol, Hotkey, Overlay, Sounds,
/// Diktier-Maschine, Verlaufsfenster.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    /// Sparkle verwaltet Suche, Download, Signaturprüfung, Austausch der App und
    /// Neustart. Als langlebiges Feld bleibt der Controller während der gesamten
    /// App-Laufzeit erhalten; mehr als eine Instanz darf es nicht geben.
    private let updaterController: SPUStandardUpdaterController
    private let makeEngine: (Config) -> DictationEngine
    private let testContext: (Config) -> DiagnosticContext

    override convenience init() {
        self.init(makeEngine: { DictationEngine(config: $0) },
                  testContext: { AppDiagnosticContext.capture(configuration: $0) }, startsUpdater: true)
    }
    // Interne Fabriken prüfen die echte App-Verdrahtung mit künstlicher Audioquelle,
    // ohne Mikrofonrechte, Alltagsdaten oder automatische Updateanfragen anzufassen.
    init(makeEngine: @escaping (Config) -> DictationEngine,
         testContext: @escaping (Config) -> DiagnosticContext, startsUpdater: Bool) {
        self.makeEngine = makeEngine; self.testContext = testContext
        updaterController = SPUStandardUpdaterController(startingUpdater: startsUpdater,
            updaterDelegate: nil, userDriverDelegate: nil)
        super.init()
    }
    private var config = Config.load()
    private var engine: DictationEngine!
    private var retiredEngineShutdowns: [Task<Void, Never>] = []
    private var terminationPending = false
    private var statusItem: NSStatusItem!
    private var hotkey: HotkeyManager!
    private var lastResultHotkey: HotkeyManager?
    private var isCapturingHotkey = false
    private var dictationHotkeyState = DictationHotkeyState()
    private var overlay: OverlayController!
    private var historyWindow: HistoryWindowController!
    private var pasteTarget: PasteService.Target?
    private let resultPreview = ResultPreviewController()
    private var resultMemory = TransientResultStore()
    private struct PreviewDelivery {
        let result: TransientResultStore.Result
        let target: PasteService.Target?
        let focus: Bool
        let floating: Bool
    }
    private var pendingResults = PendingResults<PreviewDelivery>()
    private var settingsWindow: SettingsWindowController!
    private var diagnosticsWindow: DiagnosticsWindowController!
    private var testDictationWindow: TestDictationWindowController!
    private var audioImportWindow: AudioImportWindowController!
    /// Netzwerkzugang für eigene Geräte im Heimnetz; nil = ausgeschaltet.
    private var bridge: BridgeServer?
    private var bridgeCredentialsObserver: NSObjectProtocol?
    private var bridgeTransition: Task<Void, Never>?
    private var bridgeGeneration = 0
    /// Protokoll der Brücke, das einen Neustart überlebt: `bridge.log` neben
    /// `config.json`. Absichtlich unabhängig vom Server-Objekt, damit auch ein
    /// fehlgeschlagener Start hineinschreiben kann.
    private let bridgeLog = BridgeLogFile()
    /// Pinnt das primäre Bereinigungs-Modell jede Minute neu — läuft nur im Modus
    /// "dauerhaft geladen" (siehe buildComponents); bei befristetem keep_alive nil.
    private var warmUpTimer: Timer?
    private var selectionCleanupActions: SelectionCleanupActions?
    private var temporaryPrivateHistory = false
    private var lastExternalAppBundleID: String?
    private var appActivationObserver: NSObjectProtocol?
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
        selectionCleanupActions = SelectionCleanupActions(canStart: { [weak self] in
            guard let self else { return false }; return !self.terminationPending && !self.isCapturingHotkey
        })
        NSApp.servicesProvider = selectionCleanupActions

        settingsWindow = SettingsWindowController(
            onApply: { [weak self] newConfig, expected in
                try self?.applySettings(newConfig, expected: expected)
            },
            onHotkeyRecording: { [weak self] recording in
                self?.setHotkeyCaptureActive(recording)
            }, onDiagnostics: { [weak self] in self?.showDiagnostics() }
        )
        diagnosticsWindow = DiagnosticsWindowController(
            configuration: { [weak self] in Config.load().resolvedForRequest(appBundleID: self?.targetAppBundleID) },
            bridgeState: { [weak self] in
                guard let self, self.bridgeTransition == nil else { return .unknown }
                return self.bridge?.isRunning == true ? .running : .stopped
            }, onAction: { [weak self] in self?.performDiagnosticAction($0) },
            onTestDictation: { [weak self] in self?.showTestDictation() }
        )
        testDictationWindow = TestDictationWindowController(
            engine: { [weak self] in self?.engine },
            configuration: { [weak self] in self?.prospectiveConfiguration ?? Config().resolvedForRequest() },
            nextConfiguration: { [weak self] in self?.requestConfiguration ?? Config() },
            canStart: { [weak self] in
                guard let self, !self.terminationPending, !self.isCapturingHotkey else { return false }
                return self.engine?.hasInFlightRequests == false && self.pendingResults.isEmpty
            }, onSettings: { [weak self] in self?.performDiagnosticAction($0) },
            onClosingError: { [weak self] message in
                guard let self, !self.terminationPending else { return }
                self.overlay?.show(.failure(message))
            }, context: testContext,
            onBegin: { [weak self] in self?.audioImportWindow?.releaseForRegularStart() ?? true }
        )
        audioImportWindow = AudioImportWindowController(
            engine: { [weak self] in self?.engine },
            configuration: { [weak self] in self?.prospectiveConfiguration ?? Config().resolvedForRequest() },
            nextConfiguration: { [weak self] in self?.requestConfiguration ?? Config() },
            canStart: { [weak self] in
                guard let self, !self.terminationPending, !self.isCapturingHotkey else { return false }
                return self.engine?.hasInFlightRequests == false && self.pendingResults.isEmpty
            }, onBegin: { [weak self] in self?.testDictationWindow?.releaseForRegularStart() ?? true },
            onClosingError: { [weak self] message in
                guard let self, !self.terminationPending else { return }
                self.overlay?.show(.failure(message))
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
        observeTargetApplication()
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
        if let tab = ProcessInfo.processInfo.environment["STILLEPOST_OPEN_SETTINGS"] {
            if tab == "diagnose" { showDiagnostics() }
            else if tab == "testdiktat" { showTestDictation() }
            else if tab == "audioimport" { showAudioImport() }
            else { settingsWindow.show() }
        }
        // Isolierter Screenshot-/GUI-Testweg fürs Verlaufsfenster. Zusammen mit
        // STILLEPOST_APP_SUPPORT liest er ausschließlich künstliche Testeinträge.
        if ProcessInfo.processInfo.environment["STILLEPOST_OPEN_HISTORY"] != nil {
            historyWindow.show()
        }
        // Ebenfalls für GUI-Checks: Overlay in einem bestimmten Zustand zeigen
        // (das Overlay erscheint sonst nur mitten in einem echten Diktat).
        if let preview = ProcessInfo.processInfo.environment["STILLEPOST_OVERLAY_PREVIEW"],
           preview.hasPrefix("raw-preview"),
           ProcessInfo.processInfo.environment["STILLEPOST_CONFIG"] != nil,
           ProcessInfo.processInfo.environment["STILLEPOST_APP_SUPPORT"] != nil {
            overlay.liveTranscriptPreview = prospectiveConfiguration.ui.liveTranscriptPreview
            overlay.recordingContext = L10n.format("profiles.recording", prospectiveConfiguration.profileLabel, prospectiveConfiguration.whisper.language)
            let sample = L10n.text("overlay.live_preview.sample")
            if preview != "raw-preview-waiting" {
                overlay.transcriptPreview = DictationTranscriptPreview(
                    text: preview == "raw-preview-empty-failed" ? "" :
                        (preview == "raw-preview-long" ? String(repeating: sample + " ", count: 60) + L10n.text("overlay.live_preview.sample_end") : sample),
                    hasFailedSegment: preview.hasSuffix("failed"))
            }
            if preview == "raw-preview-paused" { overlay.show(.paused) }
            else if preview == "raw-preview-resuming" { overlay.show(.starting(hold: false, resuming: true)) }
            else { overlay.show(.recording) }
        }
        if ProcessInfo.processInfo.environment["STILLEPOST_OVERLAY_PREVIEW"] != nil,
           ProcessInfo.processInfo.environment["STILLEPOST_CONFIG"] != nil,
           ProcessInfo.processInfo.environment["STILLEPOST_APP_SUPPORT"] != nil,
           prospectiveConfiguration.vad.detector == .silero {
            let vad = prospectiveConfiguration.vad
            Task { @MainActor [weak self] in
                let detector = await VadSegmenter.prepared(config: vad)
                self?.overlay.recordingVad = detector.fallbackReason.map {
                    L10n.format("vad.fallback_status", $0)
                } ?? L10n.text("vad.active")
            }
        }
        switch ProcessInfo.processInfo.environment["STILLEPOST_OVERLAY_PREVIEW"] {
        case "recording":
            overlay.recordingContext = L10n.format("profiles.recording", prospectiveConfiguration.profileLabel,
                prospectiveConfiguration.whisper.language)
            overlay.recordingReason = prospectiveConfiguration.requestProfileSelection?.label ?? ""
            overlay.recordingInstruction = config.hotkeyMode == .hold ? L10n.text("hotkey.hold.release") : ""
            overlay.show(.recording)
        case "paused":
            overlay.recordingContext = L10n.format("profiles.recording", prospectiveConfiguration.profileLabel, prospectiveConfiguration.whisper.language)
            overlay.recordingReason = prospectiveConfiguration.requestProfileSelection?.label ?? ""
            overlay.recordingInstruction = config.hotkeyMode == .hold ? L10n.text("hotkey.hold.release") : ""
            overlay.show(.paused)
        case "resuming":
            overlay.show(.starting(hold: config.hotkeyMode == .hold, resuming: true))
        case "hold-unavailable":
            overlay.show(.failure(L10n.text("hotkey.hold.unavailable")))
        case "starting":
            overlay.show(.starting(hold: config.hotkeyMode == .hold))
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
        case "clipboard-changed":
            overlay.show(.failure(L10n.text("app.paste_clipboard_changed")))
        case .some, .none:
            break
        }
        // Künstlicher Ergebnisweg für Bundle-Abnahmen, nur mit isolierten Daten.
        // Ausschließlich künstlicher Text; der lokale Prüfweg verwendet den echten Bereinigungsdienst.
        let environment = ProcessInfo.processInfo.environment
        if environment["STILLEPOST_APP_SUPPORT"] != nil,
           environment["STILLEPOST_CONFIG"] != nil,
           let test = environment["STILLEPOST_RESULT_TEST"],
           ["seed", "success", "raw", "empty", "failed", "long", "concurrent-private", "local-policy"].contains(test) {
            let synthetic = "Dies ist ein künstlicher Ergebnistext. Zahlen: 128 Euro."
            let text = test == "long"
                ? (1...80).map { "Absatz \($0): \(synthetic)" }.joined(separator: "\n\n")
                : synthetic
            if environment["STILLEPOST_RESULT_TEST_PREVIOUS"] == "1" {
                resultMemory.accept(text: "Zuvor bestätigter Testtext.", rawFallback: false)
            }
            if test == "local-policy" {
                let cleanup = prospectiveConfiguration.cleanup
                Task { @MainActor [weak self] in
                    let raw = "Die Zahl bleibt 128 und Version 2.4 wird nicht geändert."
                    let result = await CleanupService(config: cleanup).clean(raw)
                    var entry = HistoryStore.Entry(rawText: raw, cleanText: result.text, status: "ok", durationSec: 1,
                        cleanupFellBack: result.usedFallback, cleanupFallbackReason: result.fallbackReason)
                    entry.storesText = false
                    self?.engine.onResult?(DictationResult(text: result.text, entry: entry))
                }
            } else if test == "seed" {
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
                if test == "concurrent-private" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        var retry = HistoryStore.Entry(rawText: "", cleanText: "Älteres privates Wiederholungsergebnis 256.", status: "ok", durationSec: 1)
                        retry.storesText = false
                        self?.engine.onPrivateRetryResult?(retry)
                    }
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        selectionCleanupActions?.close()
        guard let engine else { return .terminateNow }
        terminationPending = true
        testDictationWindow?.prepareForTermination()
        audioImportWindow?.prepareForTermination()
        hotkey = nil
        lastResultHotkey = nil
        bridge?.stop()
        warmUpTimer?.invalidate()
        if let appActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver) }
        historyMaintenanceTimer?.invalidate()
        historyMaintenanceTask?.cancel()
        engine.onStateChange = nil
        engine.onResult = nil
        let shutdown = engine.shutdown()
        let retired = retiredEngineShutdowns
        let editSave = historyWindow?.pendingSaveTask
        historyWindow?.close()
        resultPreview.dismiss()
        Task { @MainActor in
            await editSave?.value
            await shutdown.value
            for task in retired { await task.value }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Bausteine aufbauen / Einstellungen anwenden

    /// Baut Engine, Overlay, Verlaufsfenster und Hotkey aus der aktuellen Config auf.
    /// Läuft beim Start und nach Änderungen an globalen Komponenten.
    private func buildComponents() {
        pasteTarget = nil
        let engineConfig = requestConfiguration
        engine = makeEngine(engineConfig)
        engine.requestAppBundleID = { [weak self] in self?.targetAppBundleID }
        overlay = OverlayController(config: config.ui)
        historyWindow = HistoryWindowController(engine: engine, onVocabularySaved: { [weak self] saved in
            guard let self else { return }
            self.adoptRequestSettings(saved)
            self.updateRequestConfiguration()
        })
        setupEngineCallbacks()
        startHistoryMaintenance()

        registerHotkey()

        // Klick aufs Overlay stoppt ebenfalls.
        overlay.onClickStop = { [weak self] in
            guard let self, !self.hasActiveTemporaryDictation else { return }
            if self.engine.state == .starting { self.cancelDictation() }
            else {
                if self.canRecallResult {
                    guard self.releaseTemporaryResultOwnership() else { return }
                }
                self.engine.toggle()
            }
        }
        overlay.onPauseResume = { [weak self] in self?.togglePauseResume() }
        overlay.levelProvider = { [weak self] in
            guard let self else { return (-120, 0) }
            return (self.engine.currentLevelDb, self.engine.recordingDuration)
        }

        if bridgeCredentialsObserver == nil {
            bridgeCredentialsObserver = NotificationCenter.default.addObserver(forName: .bridgeCredentialsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.startBridgeIfEnabled()
            }
        }
        startBridgeIfEnabled()

        // Bereinigungs-Modell einmal beim Start vorwärmen, damit schon das erste
        // Diktat ohne Kaltstart auskommt.
        if config.appProfiles.isEmpty || config.selectedProfileID != nil || targetAppBundleID != nil {
            engine.keepCleanupModelWarm()
        }
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
        refreshWarmUpTimer()
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
        let server = BridgeServer(config: requestConfiguration)
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
        handleDictationHotkey(.interrupted)
        dictationHotkeyState = DictationHotkeyState()
        hotkey = nil
        lastResultHotkey = nil
        func register(_ combination: Config.Hotkey, identifier: UInt32,
                      release: @escaping () -> Void = {}, interruption: @escaping () -> Void = {},
                      limit: @escaping () -> Void = {},
                      action: @escaping () -> Void) -> HotkeyManager? {
            do {
                return try HotkeyManager(config: combination, identifier: identifier,
                    onRelease: release, onInterruption: interruption, onHoldLimit: limit, onPress: action)
            } catch {
                let status = (error as? HotkeyManager.RegistrationError)?.status ?? -1
                overlay.show(.failure(L10n.format("app.hotkey_registration_failed",
                    HotkeyManager.describe(combination), status)))
                return nil
            }
        }
        let dictationCombination = config.hotkey
        let recallCombination = config.lastResultHotkey
        hotkey = register(dictationCombination, identifier: 1,
            release: { [weak self] in self?.handleDictationHotkey(.released) },
            interruption: { [weak self] in self?.handleDictationHotkey(.interrupted) },
            limit: { [weak self] in self?.handleDictationHotkey(.deadline) }) { [weak self] in
            guard let self else { return }
            self.routeHotkey(dictationCombination) { self.handleDictationHotkey(.pressed) }
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
        if active { handleDictationHotkey(.interrupted) }
        isCapturingHotkey = active
    }

    private func handleDictationHotkey(_ input: DictationHotkeyState.Input) {
        guard let engine, !terminationPending else { return }
        if hasActiveTemporaryDictation {
            if input == .released || input == .interrupted {
                _ = dictationHotkeyState.handle(input, mode: config.hotkeyMode, state: engine.state)
            }
            if input == .interrupted { testDictationWindow.cancel(); audioImportWindow.cancel() }
            return
        }
        switch dictationHotkeyState.handle(input, mode: config.hotkeyMode, state: engine.state,
            canReadKeyboardState: input != .pressed || HotkeyManager.canReadKeyboardState) {
        case .unavailable: overlay.show(.failure(L10n.text("hotkey.hold.unavailable")))
        case .none: break
        case .toggle:
            if canRecallResult {
                guard releaseTemporaryResultOwnership() else { return }
            }
            engine.toggle()
        case .start:
            guard releaseTemporaryResultOwnership() else { return }
            engine.start(onlyWhile: { [weak self] in
                self?.dictationHotkeyState.ownsHold == true && self?.hotkey?.isCombinationHeld == true
            })
        case .stop: engine.stop()
        case .cancel, .cancelAtLimit:
            cancelDictation()
            if input == .deadline && engine.state == .idle { overlay.show(.failure(L10n.text("hotkey.hold.limit"))) }
        case .stopAtLimit:
            engine.stop()
            if engine.state == .processing { overlay.show(.processing(detail: L10n.text("hotkey.hold.limit"))) }
        }
    }

    private func routeHotkey(_ combination: Config.Hotkey, perform action: () -> Void) {
        if isCapturingHotkey {
            NotificationCenter.default.post(name: HotkeyManager.captureNotification, object: combination)
        } else {
            action()
        }
    }

    private var effectiveHistoryPolicy: Config.History {
        var policy = config.resolvedForRequest().history
        if temporaryPrivateHistory { policy.storeText = false }
        return policy
    }

    @objc private func togglePrivateHistory() {
        guard config.resolvedForRequest().history.storeText else { return }
        temporaryPrivateHistory.toggle()
        engine.suppressTranscriptPreview()
        let environment = ProcessInfo.processInfo.environment
        if environment["STILLEPOST_HISTORY_TRACE"] == "1",
           environment["STILLEPOST_CONFIG"] != nil, environment["STILLEPOST_APP_SUPPORT"] != nil {
            FileHandle.standardError.write(Data("history-policy: storesText=\(effectiveHistoryPolicy.storeText)\n".utf8))
        }
        updateRequestConfiguration()
    }

    private func updatePrivateHistoryMenu() {
        let item = statusItem.menu?.items.first { $0.action == #selector(togglePrivateHistory) }
        item?.state = effectiveHistoryPolicy.storeText ? .off : .on
        item?.isEnabled = config.resolvedForRequest().history.storeText
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

    private var targetAppBundleID: String? {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           front != Bundle.main.bundleIdentifier { return front }
        return lastExternalAppBundleID
    }

    private var prospectiveConfiguration: Config {
        requestConfiguration.resolvedForRequest(appBundleID: targetAppBundleID)
    }

    private func observeTargetApplication() {
        lastExternalAppBundleID = targetAppBundleID
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            self.lastExternalAppBundleID = id
            self.statusItem.menu = self.buildMenu()
            self.updateStatusIcon(for: self.engine.state)
            self.refreshWarmUpTimer()
        }
    }

    private func refreshWarmUpTimer() {
        warmUpTimer?.invalidate()
        warmUpTimer = nil
        let cleanup = prospectiveConfiguration.cleanup
        guard cleanup.enabled,
              let endpoint = cleanup.chain.first(where: { CleanupService.endpointAllowed($0, localOnly: cleanup.localOnly) }),
              CleanupService.pinsForever(endpoint.keepAlive) else { return }
        warmUpTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.engine.keepCleanupModelWarm()
        }
    }

    private var requestConfiguration: Config {
        var result = config
        if temporaryPrivateHistory {
            result.history.storeText = false
            // Die flüchtige Datenschutzwahl hat Vorrang vor jedem Profil.
            for index in result.profiles.indices where result.profiles[index].history != nil {
                result.profiles[index].history?.storeText = false
            }
        }
        return result
    }

    private func adoptRequestSettings(_ saved: Config) {
        clearPreviewForChangedSettings(saved)
        config.appProfiles = saved.appProfiles
        config.profiles = saved.profiles
        config.defaultProfileID = saved.defaultProfileID
        config.selectedProfileID = saved.selectedProfileID
        config.whisper.language = saved.whisper.language
        config.cleanup = saved.cleanup
        config.history = saved.history
    }

    private func clearPreviewForChangedSettings(_ updated: Config) {
        if config.profiles != updated.profiles || config.selectedProfileID != updated.selectedProfileID
            || config.defaultProfileID != updated.defaultProfileID || config.appProfiles != updated.appProfiles
            || config.whisper.language != updated.whisper.language || config.cleanup != updated.cleanup
            || config.history != updated.history {
            engine.suppressTranscriptPreview()
        }
    }

    private func updateRequestConfiguration() {
        engine.configure(requestConfiguration)
        bridge?.configure(requestConfiguration)
        statusItem.menu = buildMenu()
        updateStatusIcon(for: engine.state)
        refreshWarmUpTimer()
    }

    /// Profilfelder aktualisieren nur kommende Aufträge. Änderungen an Hardware
    /// oder Bedienung dürfen einen laufenden Auftrag nicht abbrechen.
    private func applySettings(_ newConfig: Config, expected: Config) throws {
        guard !terminationPending else { return }
        var requestOnly = config
        requestOnly.history = newConfig.history
        requestOnly.cleanup = newConfig.cleanup
        requestOnly.whisper.language = newConfig.whisper.language
        requestOnly.appProfiles = newConfig.appProfiles
        requestOnly.profiles = newConfig.profiles
        requestOnly.defaultProfileID = newConfig.defaultProfileID
        requestOnly.selectedProfileID = newConfig.selectedProfileID
        requestOnly.hotkeyMode = newConfig.hotkeyMode
        requestOnly.hotkey = newConfig.hotkey
        requestOnly.lastResultHotkey = newConfig.lastResultHotkey
        requestOnly.ui.liveTranscriptPreview = newConfig.ui.liveTranscriptPreview
        let needsRebuild = requestOnly != newConfig
        let changesBindings = config.hotkey != newConfig.hotkey || config.lastResultHotkey != newConfig.lastResultHotkey
        let changesInput = config.hotkeyMode != newConfig.hotkeyMode || changesBindings
        if (needsRebuild || changesInput) && (engine.hasInFlightRequests || bridge?.hasInFlightRequests == true || !pendingResults.isEmpty) {
            throw NSError(domain: "StillePost", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.text("profiles.busy_settings")])
        }
        try newConfig.save(expected: expected)
        if !needsRebuild {
            clearPreviewForChangedSettings(newConfig)
            config = newConfig
            if changesBindings { registerHotkey() }
            updateRequestConfiguration()
            return
        }
        overlay.hide()
        if let save = historyWindow.pendingSaveTask { retiredEngineShutdowns.append(save) }
        historyWindow.close()
        retiredEngineShutdowns.append(engine.shutdown())
        config = newConfig
        buildComponents()
        statusItem.menu = buildMenu()
    }

    @objc private func selectProfile(_ item: NSMenuItem) {
        guard !terminationPending else { return }
        do {
            let id = (item.representedObject as? String).flatMap(UUID.init(uuidString:))
            adoptRequestSettings(try ConfigFile().selectProfile(id))
            updateRequestConfiguration()
        } catch { overlay.show(.failure(error.localizedDescription)) }
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
        if config.hotkeyMode == .hold {
            menu.addItem(NSMenuItem(title: L10n.format("hotkey.hold.menu", HotkeyManager.describe(config.hotkey)),
                action: nil, keyEquivalent: ""))
        }
        let pauseItem = NSMenuItem(title: L10n.text("recording.pause"), action: #selector(togglePauseResume), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)
        let cancelItem = NSMenuItem(title: L10n.text("menu.cancel_recording"),
                                    action: #selector(cancelDictation), keyEquivalent: "")
        cancelItem.target = self
        menu.addItem(cancelItem)
        menu.addItem(.separator())
        let profileItem = NSMenuItem(title: L10n.format("profiles.active", prospectiveConfiguration.profileLabel,
            prospectiveConfiguration.whisper.language), action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        let standard = NSMenuItem(title: L10n.text("profiles.use_default"), action: #selector(selectProfile(_:)), keyEquivalent: "")
        standard.target = self
        standard.state = config.selectedProfileID.flatMap { id in config.profiles.first { $0.id == id } } == nil ? .on : .off
        profileMenu.addItem(standard)
        for profile in config.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id.uuidString
            item.state = config.selectedProfileID == profile.id ? .on : .off
            profileMenu.addItem(item)
        }
        let reason = NSMenuItem(title: prospectiveConfiguration.requestProfileSelection?.label ?? "", action: nil, keyEquivalent: "")
        profileMenu.insertItem(reason, at: 0)
        if prospectiveConfiguration.cleanup.localOnly {
            profileMenu.insertItem(NSMenuItem(title: L10n.text("profiles.local_only"), action: nil, keyEquivalent: ""), at: 1)
        }
        profileItem.submenu = profileMenu
        menu.addItem(profileItem)
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
        let diagnosisItem = NSMenuItem(title: L10n.text("diagnosis.open"), action: #selector(showDiagnostics), keyEquivalent: "")
        diagnosisItem.target = self
        menu.addItem(diagnosisItem)
        let testItem = NSMenuItem(title: L10n.text("test_dictation.open"), action: #selector(showTestDictation), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        let selectionItem = NSMenuItem(title:L10n.text("selection.menu"),
            action:#selector(SelectionCleanupActions.cleanSelectedText(_:)),keyEquivalent:"")
        selectionItem.target = selectionCleanupActions
        menu.addItem(selectionItem)
        let importItem = NSMenuItem(title: L10n.text("audio_import.open"), action: #selector(showAudioImport), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)
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
        case .paused: (symbol, description) = ("pause.circle.fill", L10n.text("status.paused"))
        case .resuming: (symbol, description) = ("mic.badge.plus", L10n.text("status.resuming"))
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
        let effective = (state == .starting || state == .recording || state == .paused || state == .resuming || state == .processing)
            ? (engine?.sessionConfiguration ?? prospectiveConfiguration) : prospectiveConfiguration
        button.toolTip = description + " · " + effective.profileLabel + " · " + effective.whisper.language
            + " · " + (effective.requestProfileSelection?.label ?? "")
    }

    // MARK: - Engine-Callbacks (Zustand -> Oberfläche)

    private func setupEngineCallbacks() {
        let source = engine!
        var previousState = source.state
        engine.onTranscriptPreview = { [weak self, weak source] preview in
            guard let self, let source, self.engine === source else { return }
            let temporary = self.ownsTemporaryResult(source)
            self.overlay.transcriptPreview = temporary ? nil : preview
            self.overlay.liveTranscriptPreview = !temporary && source.isTranscriptPreviewEnabled
        }
        engine.onAudioImportStage = { [weak self, weak source] stage in
            guard let self, let source, self.engine === source, self.audioImportWindow?.owns(source) == true else { return }
            self.audioImportWindow.receiveStage(stage)
        }
        engine.onAudioImportProgress = { [weak self, weak source] progress in
            guard let self, let source, self.engine === source, self.audioImportWindow?.owns(source) == true else { return }
            self.audioImportWindow.receiveProgress(progress)
        }
        // Der Startton wird vollständig vor dem Öffnen des Mikrofons abgespielt.
        // Gerade das iPhone als Continuity-Mikrofon hört den Mac-Lautsprecher sehr
        // klar; der Ton darf deshalb nicht Teil des Whisper-Segments werden.
        engine.onBeforeRecordingStart = { [weak self, weak source] in
            guard let self, let source, self.engine === source else { return }
            await self.playSoundAndWait(custom: "dictation-start", fallback: "Pop")
        }
        engine.onStateChange = { [weak self, weak source] state in
            guard let self, let source, self.engine === source else { return }
            let priorState = previousState
            previousState = state
            self.dictationHotkeyState.didChangeState(state)
            self.updateStatusIcon(for: state)
            if self.audioImportWindow?.owns(source) == true {
                self.overlay.hide(); self.pasteTarget = nil
                self.audioImportWindow.receiveState(state)
                return
            }
            if self.testDictationWindow?.owns(source) == true {
                self.overlay.hide()
                if state == .starting { self.pasteTarget = nil }
                if state == .processing { self.playSound(custom: "dictation-stop", fallback: "Bottle") }
                if case .error = state { self.playSound(custom: nil, fallback: "Basso") }
                self.testDictationWindow.receiveState(state)
                return
            }
            self.overlay.liveTranscriptPreview = source.isTranscriptPreviewEnabled
            switch state {
            case .starting:
                self.pasteTarget = PasteService.captureTarget()
                self.overlay.show(.starting(hold: self.dictationHotkeyState.ownsHold))
            case .resuming:
                self.overlay.show(.starting(hold: self.dictationHotkeyState.ownsHold, resuming: true))
            case .paused:
                self.playSound(custom: "dictation-stop", fallback: "Bottle")
                self.overlay.show(.paused)
            case .recording:
                self.overlay.recordingVad = source.vadStatus
                self.overlay.recordingContext = L10n.format("profiles.recording", self.engine.sessionConfiguration.profileLabel,
                    self.engine.sessionConfiguration.whisper.language)
                self.overlay.recordingReason = self.engine.sessionConfiguration.requestProfileSelection?.label ?? ""
                self.overlay.recordingInstruction = self.dictationHotkeyState.ownsHold ? L10n.text("hotkey.hold.release") : ""
                self.overlay.show(.recording)
            case .processing:
                // Tieferer Whoosh/Ding: deutlich ANDERES "Aufnahme beendet"-Signal.
                self.playSound(custom: "dictation-stop", fallback: "Bottle")
                self.overlay.show(.processing())
            case .error(let message):
                self.playSound(custom: nil, fallback: "Basso")  // Fehler-Sound
                self.overlay.show(.failure(message))
            case .idle:
                // Erfolgreiche Ergebnisse kommen nach idle und brauchen ihr Ziel
                // noch. Nur ein abgebrochener Start gibt es hier bereits frei.
                if priorState == .starting { self.pasteTarget = nil }
                self.overlay.hidePreparation()
            }
        }

        engine.onResult = { [weak self, weak source] result in
            guard let self, let source, self.engine === source else { return }
            if self.audioImportWindow?.owns(source) == true {
                self.audioImportWindow.receiveResult(result)
                return
            }
            if self.testDictationWindow?.owns(source) == true {
                self.testDictationWindow.receiveResult(result)
                return
            }
            defer { self.pasteTarget = nil }
            if let entry = result.entry,
               let usable = TransientResultStore.Result(text: result.text,
                    rawFallback: entry.cleanupFellBack == true, failed: entry.isFailed, note: self.engine.sessionConfiguration.cleanup.localOnly ? entry.cleanupFallbackReason : nil, origin: entry.resultOrigin) {
                if self.engine.sessionConfiguration.ui.previewBeforePaste || !self.pendingResults.isEmpty {
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

        engine.onPrivateRetryResult = { [weak self, weak source] entry in
            guard let self, self.engine === source, let result = TransientResultStore.Result(text: entry.cleanText,
                rawFallback: entry.cleanupFellBack == true, note: entry.cleanupFallbackReason, origin: entry.resultOrigin) else { return }
            self.showPreview(result, target: PasteService.captureTarget(), focus: self.canRecallResult, floating: false)
        }

        engine.onVadFallback = { [weak self, weak source] _ in
            guard let self, let source, self.engine === source else { return }
            self.testDictationWindow?.receiveVadStatus(source.vadStatus)
            if !self.ownsTemporaryResult(source) { self.overlay.recordingVad = source.vadStatus }
        }

        // Bereinigung weicht gerade auf einen Fallback-Endpoint aus: im Overlay
        // anzeigen, damit eine evtl. längere Wartezeit erklärbar ist.
        engine.onCleanupFallback = { [weak self, weak source] label in
            guard let self, let source, self.engine === source, self.engine.state == .processing,
                  !self.ownsTemporaryResult(source) else { return }
            self.overlay.show(.processing(detail: L10n.format("app.cleanup_fallback", label)))
        }
        // Direktanfrage an den primären Endpoint ist gescheitert — es läuft sofort
        // ein zweiter Versuch über eine frische Verbindung.
        engine.onCleanupPrimaryRetry = { [weak self, weak source] in
            guard let self, let source, self.engine === source, self.engine.state == .processing,
                  !self.ownsTemporaryResult(source) else { return }
            self.overlay.show(.processing(detail: L10n.text("app.cleanup_primary_retry")))
        }
    }

    // MARK: - Menü-Aktionen

    private var hasActiveTemporaryDictation: Bool {
        testDictationWindow?.isActive == true || audioImportWindow?.isActive == true
    }
    private func ownsTemporaryResult(_ source: DictationEngine) -> Bool {
        testDictationWindow?.owns(source) == true || audioImportWindow?.owns(source) == true
    }
    private func releaseTemporaryResultOwnership() -> Bool {
        testDictationWindow?.releaseForRegularStart() != false && audioImportWindow?.releaseForRegularStart() != false
    }

    private var canRecallResult: Bool {
        guard !hasActiveTemporaryDictation else { return false }
        if case .idle = engine.state { return true }
        if case .error = engine.state { return true }
        return false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !terminationPending else { return false }
        if menuItem.action == #selector(showDiagnostics) || menuItem.action == #selector(showTestDictation) || menuItem.action == #selector(showAudioImport) { return !isCapturingHotkey }
        if menuItem.action == #selector(toggleDictation) { return !hasActiveTemporaryDictation }
        if menuItem.action == #selector(togglePauseResume) {
            guard !hasActiveTemporaryDictation else { return false }
            menuItem.title = L10n.text(engine.state == .paused ? "recording.resume" : "recording.pause")
            return engine.state == .recording || engine.state == .paused
        }
        if menuItem.action == #selector(togglePrivateHistory) { return config.resolvedForRequest().history.storeText }
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
        resultMemory.accept(text: result.text, rawFallback: result.rawFallback, note: result.note, origin: result.origin)
    }

    private func showPreview(_ result: TransientResultStore.Result, target: PasteService.Target?, focus: Bool = false, floating: Bool = true) {
        let delivery = PreviewDelivery(result: result, target: target, focus: focus, floating: floating)
        if pendingResults.append(delivery) { presentPreview(delivery) }
    }

    private func presentPreview(_ delivery: PreviewDelivery) {
        let result = delivery.result
        resultPreview.show(result, focus: delivery.focus, floating: delivery.floating) { [weak self] action in
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
                self.insert(result, target: delivery.target)
            }
            if let next = self.pendingResults.finish() { self.presentPreview(next) }
        }
    }

    private func insert(_ result: TransientResultStore.Result, target: PasteService.Target?) {
        switch PasteService.paste(result.text, target: target) {
        case .pasted:
            overlay.show(.success(note: result.rawFallback ? (result.note ?? L10n.text("app.raw_fallback_note")) : nil))
        case .clipboardOnlyScreenSharing:
            overlay.show(.clipboard(note: L10n.text("app.screen_sharing_note")))
        case .clipboardOnlyTargetChanged:
            overlay.show(.clipboard(note: L10n.text("app.paste_target_changed")))
        case .clipboardOnlyTargetUnavailable:
            overlay.show(.clipboard(note: L10n.text("app.paste_target_unavailable")))
        case .noPermission:
            overlay.show(.failure(L10n.text("app.paste_permission_missing")))
        case .clipboardChanged:
            overlay.show(.failure(L10n.text("app.paste_clipboard_changed")))
        }
    }

    @objc private func togglePauseResume() {
        guard !hasActiveTemporaryDictation else { return }
        if engine.state == .recording { engine.pause() }
        else if engine.state == .paused { engine.resume() }
    }
    @objc private func toggleDictation() {
        guard !hasActiveTemporaryDictation, releaseTemporaryResultOwnership() else { return }
        engine.toggle()
    }
    @objc private func cancelDictation() {
        pasteTarget = nil
        if audioImportWindow?.isActive == true { audioImportWindow.cancel(); return }
        if testDictationWindow?.isActive == true { testDictationWindow.cancel(); return }
        engine.cancel()
        if engine.state == .idle { overlay.hide() }
    }
    @objc private func showHistory() { if !terminationPending { historyWindow.show() } }
    @objc private func showAudioImport() {
        guard !terminationPending, !isCapturingHotkey else { return }
        audioImportWindow.show()
    }
    @objc private func showTestDictation() {
        guard !terminationPending, !isCapturingHotkey else { return }
        testDictationWindow.show()
    }

    @MainActor @objc private func showDiagnostics() {
        guard !terminationPending, !isCapturingHotkey else { return }
        diagnosticsWindow.show()
    }

    private func performDiagnosticAction(_ action: DiagnosticFinding.Action) {
        switch action {
        case .none: break
        case .recordingSettings: settingsWindow.show(tab: "aufnahme")
        case .speechSettings: settingsWindow.show(tab: "spracherkennung")
        case .cleanupSettings: settingsWindow.show(tab: "bereinigung")
        case .generalSettings: settingsWindow.show(tab: "allgemein")
        case .microphonePrivacy:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .accessibilityPrivacy:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc private func showSettings() { if !terminationPending { settingsWindow.show() } }
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
