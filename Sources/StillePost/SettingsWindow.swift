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

    init(onApply: @escaping (Config) -> Void) {
        self.onApply = onApply
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
            onCancel: { [weak self] in self?.window?.close() }
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

    init(config: Config, onApply: @escaping (Config) -> Void, onCancel: @escaping () -> Void) {
        _config = State(initialValue: config)
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
            case .allgemein: GeneralTab(config: $config)
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

    var body: some View {
        Form {
            Section("Aufnahme-Hotkey") {
                LabeledContent("Zusatztasten") {
                    HStack(spacing: 16) {
                        Toggle("⌘", isOn: modifierBinding("cmd")).toggleStyle(.checkbox)
                        Toggle("⌥", isOn: modifierBinding("opt")).toggleStyle(.checkbox)
                        Toggle("⌃", isOn: modifierBinding("ctrl")).toggleStyle(.checkbox)
                        Toggle("⇧", isOn: modifierBinding("shift")).toggleStyle(.checkbox)
                    }
                }
                LabeledContent("Taste (Keycode)") {
                    TextField("", value: $config.hotkey.keyCode, format: .number.grouping(.never))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Ergebnis") {
                    Text(HotkeyManager.describe(config.hotkey)).bold()
                }
                Text("Keycode ist der virtuelle Tastencode (Carbon), z. B. 49 = Leertaste, 2 = D.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    /// Binding für einen einzelnen Modifier ("cmd"/"opt"/…) auf die String-Liste.
    private func modifierBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { config.hotkey.modifiers.contains(name) },
            set: { on in
                if on {
                    if !config.hotkey.modifiers.contains(name) { config.hotkey.modifiers.append(name) }
                } else {
                    config.hotkey.modifiers.removeAll { $0 == name }
                }
            }
        )
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
