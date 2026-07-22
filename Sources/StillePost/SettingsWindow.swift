import AppKit
import SwiftUI
import StillePostCore

/// Fenster mit den App-Einstellungen: bearbeitet eine Kopie der Config und gibt
/// sie beim Speichern an die App zurück (die schreibt config.json und baut die
/// Bausteine neu auf). Die Datei bleibt weiterhin von Hand editierbar — das
/// Fenster liest bei jedem Öffnen frisch von Platte.
final class SettingsWindowController {

    private var window: NSWindow?
    /// Wird beim Speichern mit der neuen Config aufgerufen (App wendet sie an).
    private let onApply: (Config) -> Void
    /// true = der Hotkey-Recorder nimmt gerade auf, die App muss den globalen
    /// Hotkey solange abmelden (sonst fängt Carbon die Kombination ab).
    private let onHotkeyRecording: (Bool) -> Void

    init(onApply: @escaping (Config) -> Void, onHotkeyRecording: @escaping (Bool) -> Void) {
        self.onApply = onApply
        self.onHotkeyRecording = onHotkeyRecording
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.text("window.settings.title")
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        // Bei jedem Öffnen frisch von Platte laden — die Datei kann inzwischen
        // von Hand oder von einer anderen Stelle geändert worden sein.
        window?.contentView = NSHostingView(rootView: SettingsView(
            config: Config.load(),
            onApply: { [weak self] newConfig in
                self?.onApply(newConfig)
                self?.window?.close()
            },
            onCancel: { [weak self] in self?.window?.close() },
            onHotkeyRecording: { [weak self] recording in self?.onHotkeyRecording(recording) }
        ))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Hauptansicht

struct SettingsView: View {
    /// Die vier Einstellungs-Bereiche (eigener Umschalter statt TabView — der
    /// rendert als Fenster-Toolbar und ließ die Tabs ins Overflow-Menü rutschen).
    enum Tab: String, CaseIterable {
        case allgemein, bereinigung, spracherkennung, aufnahme
        var title: String {
            switch self {
            case .allgemein: return L10n.text("settings.tab.general")
            case .bereinigung: return L10n.text("settings.tab.cleanup")
            case .spracherkennung: return L10n.text("settings.tab.speech")
            case .aufnahme: return L10n.text("settings.tab.recording")
            }
        }
    }

    /// Arbeitskopie — erst "Speichern" gibt sie an die App weiter.
    @State var config: Config
    @State private var tab: Tab
    let onApply: (Config) -> Void
    let onCancel: () -> Void
    let onHotkeyRecording: (Bool) -> Void

    private var configValidationError: String? {
        do {
            try config.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    init(config: Config, onApply: @escaping (Config) -> Void, onCancel: @escaping () -> Void,
         onHotkeyRecording: @escaping (Bool) -> Void = { _ in }) {
        _config = State(initialValue: config)
        self.onHotkeyRecording = onHotkeyRecording
        // Automatisierte GUI-Checks können über die Env-Var direkt einen
        // bestimmten Bereich öffnen (Wert = Tab-Name, sonst "Allgemein").
        let requested = ProcessInfo.processInfo.environment["STILLEPOST_OPEN_SETTINGS"] ?? ""
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
            case .allgemein: GeneralTab(config: $config, onHotkeyRecording: onHotkeyRecording)
            case .bereinigung: CleanupTab(cleanup: $config.cleanup)
            case .spracherkennung: WhisperTab(whisper: $config.whisper)
            case .aufnahme: RecordingTab(audio: $config.audio, vad: $config.vad)
            }

            Divider()
            HStack {
                Text(configValidationError ?? L10n.text("settings.config_hint"))
                    .font(.caption)
                    .foregroundColor(configValidationError == nil ? .secondary : .red)
                Spacer()
                Button(L10n.text("common.cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("common.save")) { onApply(config) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(configValidationError != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 600, minHeight: 520)
        .environment(\.locale, Locale(identifier: L10n.languageCode))
    }
}

// MARK: - Tab: Allgemein (Hotkey + Oberfläche)

private struct GeneralTab: View {
    @Binding var config: Config
    /// Meldet der App, dass gerade eine Kombination aufgenommen wird (siehe HotkeyRecorder).
    let onHotkeyRecording: (Bool) -> Void

    var body: some View {
        Form {
            Section(L10n.text("settings.hotkey.section")) {
                HotkeyRecorder(hotkey: $config.hotkey, onRecordingChanged: onHotkeyRecording)
            }
            Section(L10n.text("settings.start.section")) {
                LoginItemToggle()
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
/// Während der Aufnahme meldet die View das der App: Die muss den globalen Hotkey
/// kurz abmelden, sonst fängt Carbon genau die Kombination ab, die aufgenommen
/// werden soll — ⌘⌥D würde ein Diktat starten statt hier anzukommen.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Config.Hotkey
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
            }
        }
        Text(hint ?? L10n.text("settings.hotkey.instructions"))
            .font(.caption)
            .foregroundColor(.secondary)
        // Fenster zu, während die Aufnahme läuft: Monitor abräumen und den globalen
        // Hotkey wieder anmelden — sonst bliebe die App ohne Hotkey zurück.
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

    /// Beendet die Aufnahme (Monitor weg, App meldet den globalen Hotkey wieder an).
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

private struct CleanupTab: View {
    @Binding var cleanup: Config.Cleanup

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("settings.cleanup.enabled"), isOn: $cleanup.enabled)
                Text(L10n.text("settings.cleanup.description"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: 500, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Section(L10n.text("settings.cleanup.api_key_section")) {
                APIKeyRow(envVar: cleanup.remote.apiKeyEnvVar)
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

    var body: some View {
        HStack {
            SecureField(L10n.text("settings.cleanup.api_key_new"), text: $newKey)
            Button(L10n.text("settings.cleanup.api_key_store")) {
                do {
                    try CleanupService.storeRemoteAPIKey(newKey)
                    newKey = ""
                    status = L10n.text("settings.cleanup.api_key_saved")
                } catch {
                    status = L10n.format("settings.cleanup.api_key_error", error.localizedDescription)
                }
            }
            .disabled(newKey.isEmpty)
        }
        HStack {
            Button(L10n.text("settings.cleanup.api_key_check")) {
                status = L10n.text("settings.cleanup.api_key_checking")
                Task.detached {
                    let found = CleanupService.remoteAPIKey(envVar: envVar) != nil
                    await MainActor.run {
                        status = found
                            ? L10n.format("settings.cleanup.api_key_found", envVar)
                            : L10n.text("settings.cleanup.api_key_missing")
                    }
                }
            }
            Text(status ?? L10n.text("settings.cleanup.api_key_privacy"))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 500, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
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
