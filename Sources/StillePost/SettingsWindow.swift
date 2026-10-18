import AppKit
import SwiftUI
import StillePostCore

/// Fenster mit den App-Einstellungen: bearbeitet eine Kopie der Config und gibt
/// sie beim Speichern an die App zurück (die schreibt config.json und aktualisiert die
/// betroffenen Bausteine). Die Datei bleibt weiterhin von Hand editierbar — das
/// Fenster liest bei jedem Öffnen frisch von Platte.
final class SettingsWindowController {

    private var window: NSWindow?
    /// Wird beim Speichern mit der neuen Config aufgerufen (App wendet sie an).
    private let onApply: (Config, Config) throws -> Void
    /// true = registrierte Hotkeys an den aktiven Recorder statt an das Diktat leiten.
    private let onHotkeyRecording: (Bool) -> Void
    private let onDiagnostics: () -> Void

    init(onApply: @escaping (Config, Config) throws -> Void, onHotkeyRecording: @escaping (Bool) -> Void,
         onDiagnostics: @escaping () -> Void = {}) {
        self.onApply = onApply
        self.onHotkeyRecording = onHotkeyRecording
        self.onDiagnostics = onDiagnostics
    }

    func show(tab: String? = nil) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.text("window.settings.title")
            window.center()
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 700, height: 680)
            self.window = window
        }
        // Bei jedem Öffnen frisch von Platte laden — die Datei kann inzwischen
        // von Hand oder von einer anderen Stelle geändert worden sein.
        let expected = Config.load()
        window?.contentView = NSHostingView(rootView: SettingsView(
            config: expected,
            onApply: { [weak self] newConfig in
                try self?.onApply(newConfig, expected)
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() },
            onHotkeyRecording: { [weak self] recording in self?.onHotkeyRecording(recording) },
            onDiagnostics: { [weak self] in self?.onDiagnostics() }, requestedTab: tab
        ))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Hauptansicht

struct SettingsView: View {
    /// Die Einstellungs-Bereiche (eigener Umschalter statt TabView — der
    /// rendert als Fenster-Toolbar und ließ die Tabs ins Overflow-Menü rutschen).
    enum Tab: String, CaseIterable {
        case allgemein, profile, apps, bereinigung, spracherkennung, aufnahme, verlauf
        var title: String {
            switch self {
            case .apps: return L10n.text("app_profiles.title")
            case .profile: return L10n.text("profiles.title")
            case .allgemein: return L10n.text("settings.tab.general")
            case .bereinigung: return L10n.text("settings.tab.cleanup")
            case .spracherkennung: return L10n.text("settings.tab.speech")
            case .aufnahme: return L10n.text("settings.tab.recording")
            case .verlauf: return L10n.text("settings.tab.history")
            }
        }
    }

    /// Arbeitskopie — erst "Speichern" gibt sie an die App weiter.
    @State var config: Config
    @State private var tab: Tab
    let onApply: (Config) throws -> Void
    @State private var saveError: String?
    let onCancel: () -> Void
    let onHotkeyRecording: (Bool) -> Void
    let onDiagnostics: () -> Void

    private var configValidationError: String? {
        do {
            try config.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    init(config: Config, onApply: @escaping (Config) throws -> Void, onCancel: @escaping () -> Void,
         onHotkeyRecording: @escaping (Bool) -> Void = { _ in },
         onDiagnostics: @escaping () -> Void = {}, requestedTab: String? = nil) {
        _config = State(initialValue: config)
        self.onDiagnostics = onDiagnostics
        self.onHotkeyRecording = onHotkeyRecording
        // Automatisierte GUI-Checks können über die Env-Var direkt einen
        // bestimmten Bereich öffnen (Wert = Tab-Name, sonst "Allgemein").
        let requested = requestedTab ?? ProcessInfo.processInfo.environment["STILLEPOST_OPEN_SETTINGS"] ?? ""
        _tab = State(initialValue: Tab(rawValue: requested) ?? .allgemein)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch tab {
            case .apps: AppProfilesTab(config: $config)
            case .profile: ProfilesTab(config: $config)
            case .allgemein: GeneralTab(config: $config, onHotkeyRecording: onHotkeyRecording, onDiagnostics: onDiagnostics)
            case .bereinigung: CleanupTab(cleanup: $config.cleanup)
            case .spracherkennung: WhisperTab(whisper: $config.whisper)
            case .aufnahme: RecordingTab(audio: $config.audio, vad: $config.vad)
            case .verlauf: HistorySettingsTab(history: $config.history)
            }

            Divider()
            HStack {
                Text(saveError ?? configValidationError ?? L10n.text("settings.config_hint"))
                    .font(.caption)
                    .foregroundColor(saveError == nil && configValidationError == nil ? .secondary : .red)
                Spacer()
                Button(L10n.text("common.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("common.save")) {
                    do { try onApply(config) }
                    catch { saveError = error.localizedDescription }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(configValidationError != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 700, minHeight: 680)
        .environment(\.locale, Locale(identifier: L10n.languageCode))
    }
}

struct HistorySettingsTab: View {
    @Binding var history: Config.History

    var body: some View {
        Form {
            Section(L10n.text("settings.history.text")) {
                Toggle(L10n.text("settings.history.store_text"), isOn: $history.storeText)
                    .accessibilityIdentifier("historyStoreText")
                Picker(L10n.text("settings.history.text_period"), selection: $history.textRetentionDays) {
                    Text(L10n.text("settings.history.unlimited")).tag(0)
                    ForEach([1, 7, 30], id: \.self) { Text($0 == 1 ? L10n.text("settings.history.day") : L10n.format("settings.history.days", $0)).tag($0) }
                }
                .disabled(!history.storeText)
                .accessibilityIdentifier("historyTextRetention")
                Text(L10n.text("settings.history.future_only"))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.text("settings.history.audio")) {
                Picker(L10n.text("settings.history.audio_period"), selection: $history.audioRetentionDays) {
                    Text(L10n.text("settings.history.manual")).tag(0)
                    ForEach([7, 30], id: \.self) { Text($0 == 1 ? L10n.text("settings.history.day") : L10n.format("settings.history.days", $0)).tag($0) }
                }
                .accessibilityIdentifier("historyAudioRetention")
                Text(L10n.text("settings.history.audio_help"))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.text("settings.history.private")) {
                Text(L10n.text("settings.history.private_help"))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("settings.history.memory_help"))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab: Allgemein (Hotkey + Oberfläche)

private struct GeneralTab: View {
    @Binding var config: Config
    /// Meldet der App, dass gerade eine Kombination aufgenommen wird (siehe HotkeyRecorder).
    let onHotkeyRecording: (Bool) -> Void
    let onDiagnostics: () -> Void
    @State private var activeRecorder: String?

    private func recordingChanged(_ recording: Bool, identifier: String) {
        if recording {
            activeRecorder = identifier
            onHotkeyRecording(true)
        } else if activeRecorder == identifier {
            activeRecorder = nil
            onHotkeyRecording(false)
        }
    }

    var body: some View {
        Form {
            Section(L10n.text("settings.hotkey.section")) {
                Picker(L10n.text("hotkey.mode"), selection: $config.hotkeyMode) {
                    Text(L10n.text("hotkey.mode.toggle")).tag(Config.HotkeyMode.toggle)
                    Text(L10n.text("hotkey.mode.hold")).tag(Config.HotkeyMode.hold)
                }
                .accessibilityIdentifier("dictationHotkeyMode")
                .disabled(activeRecorder != nil)
                Text(L10n.text("hotkey.mode.help")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HotkeyRecorder(hotkey: $config.hotkey) {
                    recordingChanged($0, identifier: "dictationHotkey")
                }
                .disabled(activeRecorder != nil && activeRecorder != "dictationHotkey")
            }
            Section(L10n.text("settings.result.section")) {
                Toggle(L10n.text("settings.live_preview"), isOn: $config.ui.liveTranscriptPreview)
                    .accessibilityIdentifier("liveTranscriptPreview")
                Text(L10n.text("settings.live_preview.help")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L10n.text("settings.result.preview"), isOn: $config.ui.previewBeforePaste)
                Text(L10n.text("settings.result.help"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HotkeyRecorder(hotkey: $config.lastResultHotkey, identifier: "lastResultHotkey",
                               onRecordingChanged: { recordingChanged($0, identifier: "lastResultHotkey") })
                    .disabled(activeRecorder != nil && activeRecorder != "lastResultHotkey")
            }
            Section(L10n.text("settings.start.section")) {
                LoginItemToggle()
            }
            Section(L10n.text("settings.bridge.section")) {
                BridgeRow(bridge: $config.bridge)
            }
            Section(L10n.text("diagnosis.title")) {
                Button(L10n.text("diagnosis.open"), action: onDiagnostics)
                    .disabled(activeRecorder != nil).accessibilityIdentifier("openDiagnostics")
                Text(L10n.text("diagnosis.saved_config")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.text("settings.interface.section")) {
                Picker(L10n.text("settings.overlay_position"), selection: $config.ui.overlayPosition) {
                    Text(L10n.text("settings.overlay_position.mouse")).tag("mouse")
                    Text(L10n.text("settings.overlay_position.bottom_center")).tag("bottomCenter")
                }
                Toggle(L10n.text("settings.sounds"), isOn: $config.ui.sounds)
            }
        }
        .formStyle(.grouped)
    }
}

/// Schalter für „Beim Anmelden starten".
///
/// Wirkt sofort statt erst beim Speichern — anders als der Rest des Dialogs, denn
/// das Login-Item steht im System und nicht in `config.json` (siehe LoginItem).
/// Der Systemzustand wird EINMAL beim Erscheinen gelesen, nicht im Renderpfad:
/// `body` muss nebenwirkungsfrei bleiben.
private struct LoginItemToggle: View {
    @State private var enabled = false
    @State private var explanation: String?
    @State private var failure: String?

    var body: some View {
        Toggle(L10n.text("settings.login_item"), isOn: $enabled)
            .disabled(!LoginItem.isAvailable)
            .onAppear {
                enabled = LoginItem.isEnabled
                explanation = LoginItem.explanation
            }
            // Alte Ein-Parameter-Signatur (statt der Sonoma-Zweiparameter-Form),
            // damit macOS 13 als Deployment-Target reicht.
            .onChange(of: enabled) { wanted in
                do {
                    try LoginItem.setEnabled(wanted)
                    failure = nil
                } catch {
                    // Zurückdrehen, statt einen Schalter zu zeigen, der lügt.
                    failure = error.localizedDescription
                    enabled = LoginItem.isEnabled
                }
                explanation = LoginItem.explanation
            }
        if let hint = failure ?? explanation {
            Text(hint)
                .font(.caption)
                .foregroundColor(failure == nil ? .secondary : .orange)
        }
    }
}

/// Nimmt eine echte Tastenkombination auf, statt sie aus Zahlen zusammensetzen zu
/// lassen (vorher musste man den Carbon-Keycode kennen — das weiß niemand auswendig).
///
/// Neue Kombinationen kommen über den lokalen Monitor. Schon registrierte
/// Kombinationen leitet die App aus Carbon hierher weiter, ohne ein Diktat oder
/// einen Ergebnisabruf auszulösen.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Config.Hotkey
    var identifier: String = "dictationHotkey"
    let onRecordingChanged: (Bool) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        LabeledContent(L10n.text("settings.hotkey.combination")) {
            HStack(spacing: 12) {
                Text(recording ? L10n.text("settings.hotkey.press_now") : HotkeyManager.describe(hotkey))
                    .bold()
                    .foregroundColor(recording ? .secondary : .primary)
                    .frame(minWidth: 110, alignment: .leading)
                Button(recording ? L10n.text("common.cancel") : L10n.text("settings.hotkey.record")) {
                    if recording { cancel() } else { start() }
                }
                .accessibilityIdentifier(identifier)
            }
        }
        Text(hint ?? L10n.text("settings.hotkey.instructions"))
            .font(.caption)
            .foregroundColor(.secondary)
        .onReceive(NotificationCenter.default.publisher(for: HotkeyManager.captureNotification)) { notification in
            guard recording, let combination = notification.object as? Config.Hotkey else { return }
            accept(combination)
        }
        // Beim Schließen auch die Umleitung registrierter Hotkeys beenden.
        .onDisappear { if recording { cancel() } }
    }

    private func start() {
        recording = true
        hint = L10n.text("settings.hotkey.capture_hint")
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil  // Event schlucken — es darf nicht in Felder/Buttons durchsickern
        }
    }

    /// Beendet Monitor und Umleitung, sodass die normalen Hotkey-Aktionen wieder gelten.
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        onRecordingChanged(false)
    }

    private func cancel() {
        stopRecording()
        hint = L10n.format("settings.hotkey.cancelled", HotkeyManager.describe(hotkey))
    }

    private func handle(_ event: NSEvent) {
        let modifiers = HotkeyManager.modifierNames(from: event.modifierFlags)
        // ⎋ ohne Zusatztasten = abbrechen. (Mit Zusatztasten darf ⎋ ein Hotkey sein.)
        if event.keyCode == 53, modifiers.isEmpty {
            cancel()
            return
        }
        var candidate = Config.Hotkey()
        candidate.keyCode = Int(event.keyCode)
        candidate.modifiers = modifiers
        accept(candidate)
    }

    private func accept(_ candidate: Config.Hotkey) {
        // Zu schwache Kombination: NICHT übernehmen, aber weiter aufnehmen — der
        // Nutzer soll einfach noch mal drücken, ohne den Knopf erneut zu suchen.
        guard candidate.isUsableGlobally else {
            hint = L10n.format("settings.hotkey.too_weak", HotkeyManager.describe(candidate))
            return
        }
        hotkey = candidate
        stopRecording()
        hint = L10n.format("settings.hotkey.new", HotkeyManager.describe(candidate))
    }
}

// MARK: - Tab: Bereinigung (Endpoint-Kette + API-Key)

struct CleanupTab: View {
    @Binding var cleanup: Config.Cleanup
    var showsVocabulary = true
    var showsFormatting = true

    init(cleanup: Binding<Config.Cleanup>, showsVocabulary: Bool = true, showsFormatting: Bool = true) {
        self._cleanup = cleanup
        self.showsVocabulary = showsVocabulary
        self.showsFormatting = showsFormatting
    }

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("settings.cleanup.enabled"), isOn: $cleanup.enabled)
                Toggle(L10n.text("profiles.local_only"), isOn: $cleanup.localOnly)
                    .accessibilityIdentifier("cleanupLocalOnly")
                Text(L10n.text("profiles.local_only_help")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("settings.cleanup.description"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showsFormatting {
                Section(L10n.text("formatting.title")) {
                    Toggle(L10n.text("formatting.enabled"), isOn: $cleanup.spokenFormatting)
                        .accessibilityIdentifier("spokenFormatting")
                    SpokenFormattingHelp()
                }
            }
            if showsVocabulary { VocabularyEditor(cleanup: $cleanup) }

            Section(L10n.text("settings.cleanup.primary")) {
                EndpointEditor(endpoint: primaryBinding)
            }

            Section {
                ForEach(cleanup.fallbacks.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(L10n.format("settings.cleanup.fallback_number", index + 1)).font(.headline)
                            Spacer()
                            Button(role: .destructive) {
                                cleanup.fallbacks.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        EndpointEditor(endpoint: $cleanup.fallbacks[index])
                    }
                }
                Button {
                    cleanup.fallbacks.append(Config.Cleanup.Endpoint())
                } label: {
                    Label(L10n.text("settings.cleanup.add_fallback"), systemImage: "plus")
                }
            } header: {
                Text(L10n.text("settings.cleanup.fallbacks"))
            } footer: {
                Text(L10n.text("settings.cleanup.fallback_help"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !cleanup.localOnly {
                Section(L10n.text("settings.cleanup.api_key_section")) {
                    APIKeyRow(envVar: cleanup.remote.apiKeyEnvVar)
                }
            } else {
                Text(L10n.text("profiles.local_no_key")).font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Der primäre Endpoint liegt in der Config als flache Felder (historisch) —
    /// dieses Binding zeigt ihn dem Editor als ganz normalen Endpoint.
    private var primaryBinding: Binding<Config.Cleanup.Endpoint> {
        Binding(
            get: {
                var endpoint = Config.Cleanup.Endpoint()
                endpoint.provider = cleanup.provider
                endpoint.ollamaURL = cleanup.ollamaURL
                endpoint.model = cleanup.model
                endpoint.numCtx = cleanup.numCtx
                endpoint.keepAlive = cleanup.keepAlive
                endpoint.remote = cleanup.remote
                return endpoint
            },
            set: { endpoint in
                cleanup.provider = endpoint.provider
                cleanup.ollamaURL = endpoint.ollamaURL
                cleanup.model = endpoint.model
                cleanup.numCtx = endpoint.numCtx
                cleanup.keepAlive = endpoint.keepAlive
                cleanup.remote = endpoint.remote
            }
        )
    }
}

/// Bearbeitet EINEN Bereinigungs-Endpoint (primär oder Fallback).
private struct EndpointEditor: View {
    @Binding var endpoint: Config.Cleanup.Endpoint

    var body: some View {
        Picker(L10n.text("settings.cleanup.provider"), selection: $endpoint.provider) {
            Text(L10n.text("settings.cleanup.provider.ollama")).tag("ollama")
            Text(L10n.text("settings.cleanup.provider.openai")).tag("openai")
        }
        if endpoint.provider == "openai" {
            TextField(L10n.text("settings.cleanup.base_url"), text: $endpoint.remote.baseURL,
                      prompt: Text("https://api.example.com/v1"))
            TextField(L10n.text("settings.cleanup.model"), text: $endpoint.remote.model)
        } else {
            TextField(L10n.text("settings.cleanup.ollama_url"), text: $endpoint.ollamaURL)
            TextField(L10n.text("settings.cleanup.model"), text: $endpoint.model)
            TextField(L10n.text("settings.cleanup.context"), value: $endpoint.numCtx,
                      format: .number.grouping(.never)
                        .locale(Locale(identifier: L10n.languageCode)))
            Picker(L10n.text("settings.cleanup.keep_alive"), selection: $endpoint.keepAlive) {
                ForEach(Self.keepAliveChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
                // Ein von Hand in die config.json geschriebener Wert (z. B. "45m")
                // steht nicht in der Liste. Ohne diesen Eintrag zeigte das Menü nichts
                // an und überschriebe den Wert beim ersten Speichern stillschweigend.
                if !Self.keepAliveChoices.contains(where: { $0.value == endpoint.keepAlive }) {
                    Text(endpoint.keepAlive).tag(endpoint.keepAlive)
                }
            }
            Text(L10n.text("settings.cleanup.keep_alive_help"))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 500, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Auswahl fürs keep_alive-Menü. Schreibweise wie bei Ollama (siehe Config).
    private static let keepAliveChoices: [(label: String, value: String)] = [
        (L10n.text("settings.cleanup.keep_alive.forever"), "-1"),
        (L10n.text("settings.cleanup.keep_alive.two_hours"), "2h"),
        (L10n.text("settings.cleanup.keep_alive.one_hour"), "1h"),
        (L10n.text("settings.cleanup.keep_alive.thirty_minutes"), "30m"),
        (L10n.text("settings.cleanup.keep_alive.twenty_minutes"), "20m"),
        (L10n.text("settings.cleanup.keep_alive.five_minutes"), "5m"),
        (L10n.text("settings.cleanup.keep_alive.unload"), "0"),
    ]
}

/// Zeile für den Cloud-API-Key: liegt NUR im Schlüsselbund, nie in der Config-Datei.
/// Ein vorhandener Key wird nie angezeigt — nur (auf Knopfdruck) ob einer da ist.
/// WICHTIG: Der Schlüsselbund wird NIE beim Rendern gelesen — SecItemCopyMatching
/// kann einen modalen Berechtigungs-Dialog auslösen und blockierte so das erste
/// Layout des Fensters (Fenster blieb 0×0). Deshalb nur asynchron auf Knopfdruck.
private struct APIKeyRow: View {
    let envVar: String
    @State private var newKey = ""
    @State private var status: String?
    /// Läuft gerade eine Schlüsselbund-Aktion? Sperrt Eingabe und Knöpfe — wie
    /// in `BridgeRow`, damit Speichern, Prüfen und ein neuer Text sich nicht
    /// überholen.
    @State private var busy = false

    var body: some View {
        HStack {
            SecureField(L10n.text("settings.cleanup.api_key_new"), text: $newKey)
                .disabled(busy)
            Button(L10n.text("settings.cleanup.api_key_store")) { store() }
                .disabled(newKey.isEmpty || busy)
        }
        HStack {
            Button(L10n.text("settings.cleanup.api_key_check")) { check() }
                .disabled(busy)
            Text(status ?? L10n.text("settings.cleanup.api_key_privacy"))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 500, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Speichert den eingegebenen Key im Schlüsselbund.
    ///
    /// Der SCHREIBzugriff läuft genauso abseits des Main-Threads wie der Lesezugriff
    /// darunter: Auch er kann den modalen Berechtigungsdialog auslösen, und der
    /// blockierte dann das Einstellungsfenster — dieselbe Begründung wie oben und
    /// in `BridgeRow`. Bisher lief er synchron im Knopfdruck.
    @MainActor private func store() {
        guard !busy else { return }
        let key = newKey
        busy = true
        status = L10n.text("settings.cleanup.api_key_storing")
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try CleanupService.storeRemoteAPIKey(key) }.value
                // Programmgesteuerte Änderungen bleiben ebenfalls erhalten;
                // geleert wird nur genau der erfolgreich gespeicherte Schnappschuss.
                if newKey == key { newKey = "" }
                status = L10n.text("settings.cleanup.api_key_saved")
            } catch {
                status = L10n.format("settings.cleanup.api_key_error", error.localizedDescription)
            }
        }
    }

    /// Meldet nur, OB ein Key hinterlegt ist — angezeigt wird er nie.
    @MainActor private func check() {
        guard !busy else { return }
        busy = true
        status = L10n.text("settings.cleanup.api_key_checking")
        Task {
            defer { busy = false }
            let found = await Task.detached {
                CleanupService.remoteAPIKey(envVar: envVar) != nil
            }.value
            status = found
                ? L10n.format("settings.cleanup.api_key_found", envVar)
                : L10n.text("settings.cleanup.api_key_missing")
        }
    }
}

/// Netzwerk-Brücke: nimmt Diktate von eigenen Geräten im Heimnetz an (iPhone).
///
/// Wie beim API-Key gilt: Der Schlüsselbund wird NIE beim Rendern angefasst, nur
/// auf ausdrücklichen Knopfdruck — ein modaler Berechtigungsdialog mitten im
/// Layout würde das Fenster blockieren.
private struct BridgeRow: View {
    @Binding var bridge: Config.Bridge
    @State private var status: String?
    /// Läuft gerade eine Schlüsselbund-Aktion? Sperrt beide Buttons und macht
    /// die Aktionen strikt seriell: Ein langsamer älterer Kopier-Task könnte
    /// sonst NACH einer schnelleren Regeneration noch das alte, inzwischen
    /// ungültige Token in die Zwischenablage legen.
    @State private var busy = false

    /// Adresse, die auf dem iPhone in den Kurzbefehl gehört (siehe BridgeAddress).
    private var address: String { BridgeAddress.baseURL(port: bridge.port) }

    var body: some View {
        Toggle(L10n.text("settings.bridge.enabled"), isOn: $bridge.enabled)
        Text(L10n.text("settings.bridge.description"))
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if bridge.enabled {
            TextField(L10n.text("settings.bridge.port"), value: $bridge.port,
                      format: .number.grouping(.never))
            LabeledContent(L10n.text("settings.bridge.address")) {
                Text(address).textSelection(.enabled).font(.caption)
            }
            HStack {
                Button(L10n.text("settings.bridge.token_copy")) { copyToken(forceNew: false) }
                    .disabled(busy)
                Button(L10n.text("settings.bridge.token_new")) { copyToken(forceNew: true) }
                    .disabled(busy)
            }
            Text(status ?? L10n.text("settings.bridge.token_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Legt bei Bedarf ein Token an und schiebt es in die Zwischenablage — von dort
    /// kommt es per Handoff direkt aufs iPhone. Angezeigt wird es nie.
    ///
    /// Ablauf strikt seriell auf dem MainActor: Schlüsselbund-Arbeit abseits des
    /// Main-Threads, danach Zwischenablage UND Status in EINEM Schritt — und
    /// solange `busy` gesetzt ist, startet kein zweiter Task.
    @MainActor private func copyToken(forceNew: Bool) {
        guard !busy else { return }
        busy = true
        status = L10n.text("settings.bridge.token_working")
        Task {
            defer { busy = false }
            do {
                let outcome = try await Self.loadOrCreateToken(forceNew: forceNew)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(outcome.token, forType: .string)
                status = outcome.created
                    ? L10n.text("settings.bridge.token_created")
                    : L10n.text("settings.bridge.token_copied")
            } catch {
                status = L10n.format("settings.cleanup.api_key_error", error.localizedDescription)
            }
        }
    }

    /// Schlüsselbundzugriff gehört nicht auf den Main-Thread (er kann einen
    /// modalen Berechtigungsdialog auslösen) — deshalb ausgelagert.
    private static func loadOrCreateToken(
        forceNew: Bool
    ) async throws -> (token: String, created: Bool) {
        try await Task.detached { () throws -> (token: String, created: Bool) in
            if forceNew {
                return (try BridgeToken.regenerate(), true)
            }
            switch BridgeToken.loadOutcome() {
            case .token(let existing):
                return (existing, false)
            case .missing:
                return (try BridgeToken.regenerate(), true)
            case .failed(let status):
                // Bewusst kein Ersatz-Token: Vielleicht liegt ein gültiges da und
                // der Schlüsselbund ist nur gesperrt — ein neues würde es
                // überschreiben und alle eingerichteten Geräte aussperren.
                throw BridgeToken.LoadError.keychain(status)
            }
        }.value
    }
}

// MARK: - Tab: Spracherkennung (Whisper)

private struct WhisperTab: View {
    @Binding var whisper: Config.Whisper

    var body: some View {
        Form {
            Section {
                TextField(L10n.text("settings.whisper.language"), text: $whisper.language)
                Text(L10n.text("settings.whisper.language_help"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L10n.text("settings.whisper.advanced")) {
                Toggle(L10n.text("settings.whisper.autostart"), isOn: $whisper.autostart)
                TextField(L10n.text("settings.whisper.server_url"), text: $whisper.serverURL)
                    .frame(maxWidth: 360)
                TextField(L10n.text("settings.whisper.binary"), text: $whisper.binaryPath)
                    .frame(maxWidth: 360)
                TextField(L10n.text("settings.whisper.model_file"), text: $whisper.modelPath)
                    .frame(maxWidth: 360)
                TextField(L10n.text("settings.whisper.cpu_threads"), value: $whisper.threads,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab: Aufnahme (Mikrofon + Stille-Erkennung)

private struct RecordingTab: View {
    @Binding var audio: Config.Audio
    @Binding var vad: Config.Vad

    var body: some View {
        Form {
            Section(L10n.text("settings.audio.section")) {
                AudioInputPicker(audio: $audio)
            }
            Section(L10n.text("settings.vad.section")) {
                TextField(L10n.text("settings.vad.threshold"), value: $vad.silenceThresholdDb,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
                Text(L10n.text("settings.vad.threshold_help"))
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L10n.text("settings.vad.split_after_silence"), value: $vad.splitAfterSilenceSec,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
                TextField(L10n.text("settings.vad.min_segment"), value: $vad.minSegmentSec,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
                TextField(L10n.text("settings.vad.max_segment"), value: $vad.maxSegmentSec,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
                TextField(L10n.text("settings.vad.padding"), value: $vad.paddingSec,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
            }
            Section(L10n.text("settings.vad.absence")) {
                TextField(L10n.text("settings.vad.auto_stop"), value: $vad.autoStopAfterSilenceSec,
                          format: .number.locale(Locale(identifier: L10n.languageCode)))
            }
        }
        .formStyle(.grouped)
    }
}

/// Zeigt die gerade von CoreAudio gemeldeten Eingabegeräte. Das Aktualisieren ist
/// absichtlich sichtbar: Ein iPhone taucht oft erst auf, nachdem es gesperrt und
/// bereitgelegt wurde, während das Einstellungsfenster schon offen ist.
private struct AudioInputPicker: View {
    @Binding var audio: Config.Audio
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDeviceName: String?

    var body: some View {
        LabeledContent(L10n.text("settings.audio.input_device")) {
            HStack {
                Picker("", selection: $audio.inputDeviceUID) {
                    Text(systemDefaultLabel).tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if selectedDeviceIsMissing {
                        Text(L10n.format("settings.audio.unavailable", selectedDeviceName))
                            .tag(audio.inputDeviceUID)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 280)

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.text("settings.audio.refresh"))
            }
        }
        Text(L10n.text("settings.audio.help"))
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: 500, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
        .onChange(of: audio.inputDeviceUID) { uid in
            if uid.isEmpty {
                audio.inputDeviceName = ""
            } else if let device = devices.first(where: { $0.uid == uid }) {
                audio.inputDeviceName = device.name
            }
        }
    }

    private var systemDefaultLabel: String {
        guard let defaultDeviceName else {
            return L10n.text("settings.audio.system_default")
        }
        return L10n.format("settings.audio.system_default_named", defaultDeviceName)
    }

    private var selectedDeviceIsMissing: Bool {
        !audio.inputDeviceUID.isEmpty
            && !devices.contains(where: { $0.uid == audio.inputDeviceUID })
    }

    private var selectedDeviceName: String {
        audio.inputDeviceName.isEmpty ? audio.inputDeviceUID : audio.inputDeviceName
    }

    private func refresh() {
        devices = AudioInputDeviceCatalog.availableDevices()
        defaultDeviceName = AudioInputDeviceCatalog.defaultDevice()?.name
        if let selected = devices.first(where: { $0.uid == audio.inputDeviceUID }) {
            audio.inputDeviceName = selected.name
        }
    }
}

struct VocabularyEditor: View {
    @Binding var cleanup: Config.Cleanup
    @State private var dictionaryText: String

    init(cleanup: Binding<Config.Cleanup>) {
        _cleanup = cleanup
        _dictionaryText = State(initialValue: cleanup.wrappedValue.dictionary.joined(separator: "\n"))
    }

    var body: some View {
        Section(L10n.text("settings.cleanup.dictionary")) {
            TextEditor(text: $dictionaryText)
                .font(.body.monospaced())
                .frame(minHeight: 100)
                .accessibilityLabel(L10n.text("settings.cleanup.dictionary"))
                .accessibilityIdentifier("dictionaryTerms")
                .onChange(of: dictionaryText) { text in
                    cleanup.dictionary = text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            Text(L10n.text("settings.cleanup.dictionary_help"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(cleanup.dictionaryVariants.indices, id: \.self) { index in
                HStack {
                    Text(verbatim: cleanup.dictionaryVariants[index].source + " → " + cleanup.dictionaryVariants[index].target)
                        .textSelection(.enabled)
                    Spacer()
                    Button(L10n.text("common.delete")) { cleanup.dictionaryVariants.remove(at: index) }
                        .accessibilityLabel(L10n.format("settings.cleanup.remove_variant", cleanup.dictionaryVariants[index].source))
                }
            }
            if !cleanup.dictionaryVariants.isEmpty {
                Text(L10n.text("settings.cleanup.variants_help"))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
