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
            window.title = "Stille Post — Einstellungen"
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
            case .allgemein: return "Allgemein"
            case .bereinigung: return "Bereinigung"
            case .spracherkennung: return "Spracherkennung"
            case .aufnahme: return "Aufnahme"
            }
        }
    }

    /// Arbeitskopie — erst "Speichern" gibt sie an die App weiter.
    @State var config: Config
    @State private var tab: Tab
    let onApply: (Config) -> Void
    let onCancel: () -> Void
    let onHotkeyRecording: (Bool) -> Void

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
            case .aufnahme: VadTab(vad: $config.vad)
            }

            Divider()
            HStack {
                Text("Einstellungen liegen in config.json — Handbearbeitung bleibt möglich.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Abbrechen") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { onApply(config) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 600, minHeight: 520)
    }
}

// MARK: - Tab: Allgemein (Hotkey + Oberfläche)

private struct GeneralTab: View {
    @Binding var config: Config
    /// Meldet der App, dass gerade eine Kombination aufgenommen wird (siehe HotkeyRecorder).
    let onHotkeyRecording: (Bool) -> Void

    var body: some View {
        Form {
            Section("Aufnahme-Hotkey") {
                HotkeyRecorder(hotkey: $config.hotkey, onRecordingChanged: onHotkeyRecording)
            }
            Section("Start") {
                LoginItemToggle()
            }
            Section("Oberfläche") {
                Picker("Overlay-Position", selection: $config.ui.overlayPosition) {
                    Text("An der Mausposition").tag("mouse")
                    Text("Unten mittig").tag("bottomCenter")
                }
                Toggle("Start-/Stopp-/Fehler-Sounds abspielen", isOn: $config.ui.sounds)
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
        Toggle("Stille Post beim Anmelden starten", isOn: $enabled)
            .disabled(!LoginItem.isAvailable)
            .onAppear {
                enabled = LoginItem.isEnabled
                explanation = LoginItem.explanation
            }
            .onChange(of: enabled) { _, wanted in
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
        LabeledContent("Tastenkombination") {
            HStack(spacing: 12) {
                Text(recording ? "Jetzt drücken …" : HotkeyManager.describe(hotkey))
                    .bold()
                    .foregroundColor(recording ? .secondary : .primary)
                    .frame(minWidth: 110, alignment: .leading)
                Button(recording ? "Abbrechen" : "Hotkey aufnehmen") {
                    if recording { cancel() } else { start() }
                }
            }
        }
        Text(hint ?? "„Hotkey aufnehmen“ drücken und die gewünschte Kombination tippen — mindestens ⌘, ⌥ oder ⌃ dabei.")
            .font(.caption)
            .foregroundColor(.secondary)
        // Fenster zu, während die Aufnahme läuft: Monitor abräumen und den globalen
        // Hotkey wieder anmelden — sonst bliebe die App ohne Hotkey zurück.
        .onDisappear { if recording { cancel() } }
    }

    private func start() {
        recording = true
        hint = "Kombination drücken. ⎋ bricht ab."
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
        hint = "Abgebrochen — es bleibt bei \(HotkeyManager.describe(hotkey))."
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
            hint = "\(HotkeyManager.describe(candidate)) reicht nicht: Ohne ⌘, ⌥ oder ⌃ wäre die Taste systemweit blockiert. Bitte noch mal."
            return
        }
        hotkey = candidate
        stopRecording()
        hint = "Neu: \(HotkeyManager.describe(candidate)) — mit „Speichern“ übernehmen."
    }
}

// MARK: - Tab: Bereinigung (Endpoint-Kette + API-Key)

private struct CleanupTab: View {
    @Binding var cleanup: Config.Cleanup

    var body: some View {
        Form {
            Section {
                Toggle("Textbereinigung aktivieren", isOn: $cleanup.enabled)
                Text("Entfernt Füllwörter/Versprecher und repariert Satzzeichen. Aus = roher Whisper-Text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Primärer Endpoint") {
                EndpointEditor(endpoint: primaryBinding)
            }

            Section {
                ForEach(cleanup.fallbacks.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Fallback \(index + 1)").font(.headline)
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
                    Label("Fallback hinzufügen", systemImage: "plus")
                }
            } header: {
                Text("Fallbacks")
            } footer: {
                Text("Wird der Reihe nach probiert, wenn der primäre Endpoint nicht antwortet (Probe-Timeout 2 s) — z. B. starker Rechner im Netz → lokales Ollama → Cloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("API-Key für OpenAI-kompatible Endpoints") {
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
        Picker("Anbieter", selection: $endpoint.provider) {
            Text("Ollama (lokal oder eigenes Netz)").tag("ollama")
            Text("OpenAI-kompatibel (Cloud, nur Text)").tag("openai")
        }
        if endpoint.provider == "openai" {
            TextField("Base-URL (inkl. /v1)", text: $endpoint.remote.baseURL, prompt: Text("https://api.example.com/v1"))
            TextField("Modell", text: $endpoint.remote.model)
        } else {
            TextField("Ollama-URL", text: $endpoint.ollamaURL)
            TextField("Modell", text: $endpoint.model)
            TextField("Kontextfenster (num_ctx)", value: $endpoint.numCtx, format: .number.grouping(.never))
            Picker("Geladen lassen (keep_alive)", selection: $endpoint.keepAlive) {
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
            Text("Wie lange Ollama das Modell nach dem Diktat im Speicher behält. Die App stellt das bei jeder Anfrage selbst ein — in Ollama ist dafür nichts zu konfigurieren. „Dauerhaft“ vermeidet jeden Kaltstart, belegt den Speicher aber durchgehend.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Auswahl fürs keep_alive-Menü. Schreibweise wie bei Ollama (siehe Config).
    private static let keepAliveChoices: [(label: String, value: String)] = [
        ("dauerhaft geladen", "-1"),
        ("2 Stunden", "2h"),
        ("1 Stunde", "1h"),
        ("30 Minuten", "30m"),
        ("20 Minuten", "20m"),
        ("5 Minuten", "5m"),
        ("sofort entladen", "0"),
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
            SecureField("Neuen API-Key eintragen", text: $newKey)
            Button("Im Schlüsselbund speichern") {
                do {
                    try CleanupService.storeRemoteAPIKey(newKey)
                    newKey = ""
                    status = "Gespeichert."
                } catch {
                    status = "Fehler: \(error.localizedDescription)"
                }
            }
            .disabled(newKey.isEmpty)
        }
        HStack {
            Button("Status prüfen") {
                status = "Prüfe …"
                Task.detached {
                    let found = CleanupService.remoteAPIKey(envVar: envVar) != nil
                    await MainActor.run {
                        status = found
                            ? "Ein Key ist hinterlegt (Schlüsselbund oder Umgebungsvariable \(envVar))."
                            : "Noch kein Key hinterlegt."
                    }
                }
            }
            Text(status ?? "Der Key wird nie angezeigt und nie in der Config-Datei gespeichert.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Tab: Spracherkennung (Whisper)

private struct WhisperTab: View {
    @Binding var whisper: Config.Whisper

    var body: some View {
        Form {
            Section {
                TextField("Sprache", text: $whisper.language)
                Text("Empfehlung: festnageln (z. B. \"de\"). Bei \"auto\" rät Whisper pro Sprech-Segment und übersetzt bei Fehl-Erkennung ungefragt.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Erweitert") {
                Toggle("whisper-server automatisch starten", isOn: $whisper.autostart)
                TextField("Server-URL", text: $whisper.serverURL)
                TextField("Server-Binary", text: $whisper.binaryPath)
                TextField("Modell-Datei", text: $whisper.modelPath)
                TextField("CPU-Threads", value: $whisper.threads, format: .number)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tab: Aufnahme (Stille-Erkennung)

private struct VadTab: View {
    @Binding var vad: Config.Vad

    var body: some View {
        Form {
            Section("Stille-Erkennung") {
                TextField("Stille-Schwelle (dBFS)", value: $vad.silenceThresholdDb, format: .number)
                Text("Pegel unterhalb dieser Schwelle gilt als Stille (0 = Vollaussteuerung, Sprache liegt deutlich über −40).")
                    .font(.caption).foregroundColor(.secondary)
                TextField("Segment schneiden nach Stille (s)", value: $vad.splitAfterSilenceSec, format: .number)
                TextField("Mindest-Segmentlänge (s)", value: $vad.minSegmentSec, format: .number)
                TextField("Maximale Segmentlänge (s)", value: $vad.maxSegmentSec, format: .number)
                TextField("Vor-/Nachlauf um Sprache (s)", value: $vad.paddingSec, format: .number)
            }
            Section("Abwesenheit") {
                TextField("Auto-Stopp nach Stille (s, 0 = aus)", value: $vad.autoStopAfterSilenceSec, format: .number)
            }
        }
        .formStyle(.grouped)
    }
}
