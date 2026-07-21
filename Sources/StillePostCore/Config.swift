import Foundation

/// Zentrale Konfiguration der App.
///
/// Wird als JSON-Datei unter `~/Library/Application Support/StillePost/config.json`
/// gespeichert. Fehlt die Datei, gelten die Default-Werte unten und die Datei wird
/// beim ersten Start mit den Defaults angelegt — so kann man sie direkt editieren.
/// Jedes Feld ist optional dekodierbar: Eine alte Config-Datei mit fehlenden Feldern
/// bekommt automatisch die Defaults für die neuen Felder (kein Crash nach Updates).
public struct Config: Codable, Equatable {

    // MARK: - Unterbereiche

    /// Einstellungen für die Spracherkennung (whisper.cpp-Server).
    public struct Whisper: Codable, Equatable {
        /// URL des whisper-server (whisper.cpp). Läuft normalerweise lokal.
        public var serverURL: String = "http://127.0.0.1:8181"
        /// Soll die App den whisper-server selbst starten, falls er nicht läuft?
        public var autostart: Bool = true
        /// Pfad zum whisper-server-Binary (Homebrew-Standardpfad).
        public var binaryPath: String = "/opt/homebrew/bin/whisper-server"
        /// Pfad zur Modell-Datei (ggml-Format). Tilde wird expandiert.
        /// Default: eigener Modell-Ordner; `scripts/install-model.sh` legt das Modell dort ab.
        public var modelPath: String = "~/Library/Application Support/StillePost/models/ggml-large-v3-turbo.bin"
        /// Anzahl CPU-Threads für den Server.
        public var threads: Int = 4
        /// Sprache für Whisper: "auto" = automatisch erkennen, sonst z. B. "de".
        public var language: String = "auto"

        public init() {}
    }

    /// Einstellungen für die Textbereinigung (LLM).
    ///
    /// Zwei Wege:
    ///  - "ollama" (Default): Modell über Ollama — lokal oder ein anderer Rechner im
    ///    eigenen Netz (z. B. ein starker Desktop-Mac als Bereinigungs-Server).
    ///  - "openai": beliebiger OpenAI-kompatibler Anbieter (Base-URL + Modell + API-Key).
    ///    Dabei geht NUR der transkribierte TEXT an den Anbieter — das Audio bleibt
    ///    in jedem Fall lokal (die Spracherkennung läuft immer auf dem eigenen Rechner).
    ///
    /// Die Felder oben beschreiben den PRIMÄREN Endpoint. Zusätzlich kann `fallbacks`
    /// weitere Endpoints auflisten, die der Reihe nach probiert werden, wenn der
    /// primäre nicht erreichbar ist oder einen Fehler liefert (z. B. Laptop unterwegs
    /// -> Desktop-Mac nicht im Netz -> lokales Ollama übernimmt).
    public struct Cleanup: Codable, Equatable {
        /// Textbereinigung überhaupt durchführen? (false = nur rohe Transkription)
        public var enabled: Bool = true
        /// "ollama" (lokal) oder "openai" (OpenAI-kompatibler Endpoint, z. B. MiniMax).
        public var provider: String = "ollama"
        /// Ollama-Endpoint (wir nutzen die native /api/chat-API).
        public var ollamaURL: String = "http://127.0.0.1:11434"
        /// Modellname in Ollama. `qwen3.5:9b` war im eigenen Vergleich der beste Kompromiss
        /// aus Geschwindigkeit und Genauigkeit (verfälscht keine Eigennamen).
        public var model: String = "qwen3.5:9b"
        /// Kontextfenster (num_ctx) für Ollama. WICHTIG auf Rechnern mit wenig RAM:
        /// Ollama-Installationen haben teils riesige globale Defaults (z. B. 131072),
        /// dann belegt ein 9B-Modell 14 GB statt ~8 GB und der Runner stirbt auf
        /// 18-GB-Macs. 16384 reicht auch für sehr lange Diktate locker.
        public var numCtx: Int = 16384
        /// Wie lange Ollama das Modell nach der letzten Anfrage im Speicher behält
        /// (`keep_alive`). Schreibweise wie bei Ollama: `"2h"`, `"30m"`, `"0"`
        /// (sofort entladen) oder `"-1"` (dauerhaft geladen).
        ///
        /// Diese Einstellung schickt die App bei JEDER Anfrage mit — in Ollama selbst
        /// ist dafür nichts zu konfigurieren. Der Default `"2h"` ist ein Kompromiss:
        /// Diktiert man innerhalb von zwei Stunden erneut, ist das Modell sofort da;
        /// danach gibt Ollama den Speicher von selbst frei. Ein Kaltstart fällt dabei
        /// selten ins Gewicht, weil das Modell schon beim Aufnahme-START vorgewärmt
        /// wird und lädt, während man noch spricht (siehe CleanupService.warmUp()).
        ///
        /// `"-1"` (dauerhaft) hält den Speicher belegt, vermeidet dafür jeden
        /// Kaltstart — sinnvoll auf einem Rechner mit viel RAM.
        public var keepAlive: String = "2h"
        /// Einstellungen für den OpenAI-kompatiblen Weg (nur relevant bei provider="openai").
        public var remote: Remote = Remote()
        /// Ausweich-Endpoints in Probier-Reihenfolge (leer = kein Fallback, nur der
        /// primäre Endpoint oben). Jeder Eintrag hat dieselben Felder wie der primäre.
        public var fallbacks: [Endpoint] = []

        /// Ein einzelner Bereinigungs-Endpoint (gleiche Bedeutung der Felder wie oben).
        public struct Endpoint: Codable, Equatable {
            public var provider: String = "ollama"
            public var ollamaURL: String = "http://127.0.0.1:11434"
            public var model: String = "qwen3.5:9b"
            public var numCtx: Int = 16384
            /// Wie beim primären Endpoint — hier aber mit `"30m"` als Default: Springt
            /// z. B. wegen eines Netz-Aussetzers das lokale Modell ein, soll es auf
            /// einem knappen Laptop nicht stundenlang RAM belegen. 30 Minuten
            /// überbrücken eine Diktier-Sitzung ohne wiederholte Kaltstarts.
            public var keepAlive: String = "30m"
            public var remote: Remote = Remote()

            public init() {}

            /// Kurzbezeichnung für Logs/Diagnose ("welcher Endpoint hat geputzt?").
            public var label: String {
                provider == "openai"
                    ? "\(remote.model) @ \(remote.baseURL)"
                    : "\(model) @ \(ollamaURL)"
            }
        }

        /// Die vollständige Probier-Kette: primärer Endpoint (aus den Feldern oben)
        /// gefolgt von den konfigurierten Fallbacks.
        public var chain: [Endpoint] {
            var primary = Endpoint()
            primary.provider = provider
            primary.ollamaURL = ollamaURL
            primary.model = model
            primary.numCtx = numCtx
            primary.keepAlive = keepAlive
            primary.remote = remote
            return [primary] + fallbacks
        }

        public struct Remote: Codable, Equatable {
            /// Basis-URL des Anbieters inkl. /v1 (Beispiel: "https://api.example.com/v1").
            public var baseURL: String = ""
            /// Modellname beim Anbieter.
            public var model: String = ""
            /// Der API-Key wird NIE in dieser Datei gespeichert. Bezugsquellen in
            /// dieser Reihenfolge: 1. Umgebungsvariable (Name unten), 2. macOS-Schlüsselbund
            /// (Eintrag anlegen mit: stillepost-cli set-cleanup-key).
            public var apiKeyEnvVar: String = "STILLEPOST_CLEANUP_API_KEY"

            public init() {}
        }

        public init() {}
    }

    /// Einstellungen für die Stille-Erkennung (VAD = Voice Activity Detection).
    public struct Vad: Codable, Equatable {
        /// Pegel-Schwelle in dBFS, unterhalb derer ein Frame als "still" gilt.
        /// 0 dBFS = Vollaussteuerung; typische Sprechpegel liegen deutlich über -40.
        public var silenceThresholdDb: Double = -45
        /// So viel Sprache (aufsummiert, nicht am Stück) muss ein Segment mindestens
        /// enthalten, damit es als "hat Sprache" gilt und überhaupt an Whisper geht.
        ///
        /// Ohne diese Schwelle genügte EIN Frame (30 ms) über der Pegelgrenze — ein
        /// Tastenklick beim Stoppen der Aufnahme reichte also, um ein sonst stilles
        /// Segment an Whisper zu schicken, das darauf "Vielen Dank." erfindet.
        /// Gemessen: Klicks liegen bei 0,03–0,06 s, die kürzesten echten Wörter
        /// ("ja", "doch") bei 0,27 s. 0,15 s liegt sicher dazwischen.
        public var minSpeechSec: Double = 0.15
        /// So viele Sekunden Stille am Stück beenden ein Sprech-Segment
        /// (dann wird das Segment sofort transkribiert, während die Aufnahme weiterläuft).
        public var splitAfterSilenceSec: Double = 0.7
        /// Segmente kürzer als das werden nicht abgeschlossen, sondern weitergeführt
        /// (verhindert Mini-Schnipsel, mit denen Whisper schlecht arbeitet).
        public var minSegmentSec: Double = 1.5
        /// Hard-Limit: spätestens nach so vielen Sekunden wird ein Segment geschnitten,
        /// auch ohne Sprechpause (Whisper arbeitet intern ohnehin in 30-s-Fenstern).
        public var maxSegmentSec: Double = 30
        /// Vor-/Nachlauf in Sekunden, der um erkannte Sprache herum mitgenommen wird
        /// (gegen abgeschnittene Wortanfänge/-enden).
        public var paddingSec: Double = 0.25
        /// Abwesenheitserkennung: Nach so vielen Sekunden durchgehender Stille wird die
        /// Aufnahme automatisch gestoppt. 0 = ausgeschaltet.
        public var autoStopAfterSilenceSec: Double = 90

        public init() {}
    }

    /// Auswahl des Aufnahmegeräts. Eine leere UID bedeutet „Systemstandard“.
    public struct Audio: Codable, Equatable {
        /// Stabile CoreAudio-UID des ausgewählten Eingabegeräts.
        public var inputDeviceUID: String = ""
        /// Letzter bekannter Anzeigename für eine verständliche Fehlermeldung, falls
        /// das Gerät beim nächsten Diktat nicht mehr verbunden ist.
        public var inputDeviceName: String = ""

        public init() {}
    }

    /// Einstellungen für die Bedienoberfläche.
    public struct UI: Codable, Equatable {
        /// Wo das Aufnahme-Overlay erscheint: "mouse" (an der Mausposition — auch bei
        /// aktivierter Bildschirm-Zoom-Funktion sichtbar, weil der Zoom dem Cursor folgt)
        /// oder "bottomCenter" (unten mittig auf dem Hauptbildschirm).
        public var overlayPosition: String = "mouse"
        /// Deutliche Start-/Stopp-/Fehler-Sounds abspielen (zoom-unabhängiges Feedback).
        public var sounds: Bool = true

        public init() {}
    }

    /// Einstellungen für den globalen Hotkey (Aufnahme ein/aus, Toggle).
    public struct Hotkey: Codable, Equatable {
        /// Virtueller Keycode (Carbon). 2 = Taste "D" auf ANSI-Tastaturen.
        public var keyCode: Int = 2
        /// Modifier als Liste von Strings: "cmd", "opt", "ctrl", "shift".
        /// Default ⌘⌥D — gleiche Belegung wie der frühere Hammerspoon-Prototyp.
        public var modifiers: [String] = ["cmd", "opt"]

        /// Taugt die Kombination als GLOBALER Hotkey? Ohne ⌘, ⌥ oder ⌃ würde die
        /// Taste systemweit abgefangen — man könnte das Zeichen dann nirgends mehr
        /// tippen. ⇧ allein reicht deshalb NICHT: ⇧D ist ein Großbuchstabe, den man
        /// beim Schreiben braucht. Der Hotkey-Recorder lehnt solche Kombinationen ab.
        public var isUsableGlobally: Bool {
            let strong = ["cmd", "command", "opt", "option", "alt", "ctrl", "control"]
            return modifiers.contains { strong.contains($0.lowercased()) }
        }

        public init() {}
    }

    // MARK: - Felder

    public var whisper: Whisper = Whisper()
    public var cleanup: Cleanup = Cleanup()
    public var vad: Vad = Vad()
    public var audio: Audio = Audio()
    public var ui: UI = UI()
    public var hotkey: Hotkey = Hotkey()

    public init() {}

    // MARK: - Laden / Speichern

    /// Basis-Ordner der App für Config, Verlauf, Modelle und (temporäre) Aufnahmen.
    public static var appSupportDir: URL {
        // Headless-GUI-Tests und Screenshots brauchen einen vollständig isolierten
        // Verlauf. So wird niemals die persönliche history.json geöffnet oder
        // verändert. Im Normalbetrieb ist die Variable nicht gesetzt.
        if let override = ProcessInfo.processInfo.environment["STILLEPOST_APP_SUPPORT"],
           !override.isEmpty {
            return URL(fileURLWithPath: expandPath(override))
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StillePost")
    }

    public static var configFile: URL {
        // Env-Override: erlaubt Tests und Skripten eine eigene Config-Datei,
        // ohne die persönliche Konfiguration anzufassen.
        if let override = ProcessInfo.processInfo.environment["STILLEPOST_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: expandPath(override))
        }
        return appSupportDir.appendingPathComponent("config.json")
    }

    /// Lädt die Config von Platte; fehlt sie, werden Defaults geschrieben und benutzt.
    /// Eine kaputte Datei führt nicht zum Absturz, sondern zu Defaults (mit Warnung auf stderr).
    public static func load() -> Config {
        let url = configFile
        guard let data = try? Data(contentsOf: url) else {
            let config = Config()
            try? config.save()
            return config
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            let message = L10n.format("core.config.unreadable", String(describing: error))
            FileHandle.standardError.write(Data(message.utf8))
            return Config()
        }
    }

    /// Schreibt die Config als hübsch formatiertes JSON (damit sie von Hand editierbar bleibt).
    public func save() throws {
        try FileManager.default.createDirectory(at: Config.appSupportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Config.configFile, options: .atomic)
    }

    /// Expandiert `~` in Pfaden aus der Config zu einem absoluten Pfad.
    public static func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - Tolerantes Dekodieren (fehlende Felder -> Defaults)

    private enum CodingKeys: String, CodingKey { case whisper, cleanup, vad, audio, ui, hotkey }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whisper = (try? c.decode(Whisper.self, forKey: .whisper)) ?? Whisper()
        cleanup = (try? c.decode(Cleanup.self, forKey: .cleanup)) ?? Cleanup()
        vad = (try? c.decode(Vad.self, forKey: .vad)) ?? Vad()
        audio = (try? c.decode(Audio.self, forKey: .audio)) ?? Audio()
        ui = (try? c.decode(UI.self, forKey: .ui)) ?? UI()
        hotkey = (try? c.decode(Hotkey.self, forKey: .hotkey)) ?? Hotkey()
    }
}

// Auch die Unterstrukturen tolerant dekodieren: Jedes fehlende Feld fällt auf den
// Default zurück. Dafür nutzen wir `decodeIfPresent` in Hand-Implementierungen.
extension Config.Whisper {
    private enum CodingKeys: String, CodingKey { case serverURL, autostart, binaryPath, modelPath, threads, language }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? serverURL
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? autostart
        binaryPath = try c.decodeIfPresent(String.self, forKey: .binaryPath) ?? binaryPath
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? modelPath
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? threads
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
    }
}

extension Config.Cleanup {
    private enum CodingKeys: String, CodingKey { case enabled, provider, ollamaURL, model, numCtx, keepAlive, remote, fallbacks }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? ollamaURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        numCtx = try c.decodeIfPresent(Int.self, forKey: .numCtx) ?? numCtx
        keepAlive = try c.decodeIfPresent(String.self, forKey: .keepAlive) ?? keepAlive
        remote = try c.decodeIfPresent(Config.Cleanup.Remote.self, forKey: .remote) ?? remote
        fallbacks = try c.decodeIfPresent([Config.Cleanup.Endpoint].self, forKey: .fallbacks) ?? fallbacks
    }
}

extension Config.Cleanup.Endpoint {
    private enum CodingKeys: String, CodingKey { case provider, ollamaURL, model, numCtx, keepAlive, remote }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? provider
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? ollamaURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        numCtx = try c.decodeIfPresent(Int.self, forKey: .numCtx) ?? numCtx
        keepAlive = try c.decodeIfPresent(String.self, forKey: .keepAlive) ?? keepAlive
        remote = try c.decodeIfPresent(Config.Cleanup.Remote.self, forKey: .remote) ?? remote
    }
}

extension Config.Cleanup.Remote {
    private enum CodingKeys: String, CodingKey { case baseURL, model, apiKeyEnvVar }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        apiKeyEnvVar = try c.decodeIfPresent(String.self, forKey: .apiKeyEnvVar) ?? apiKeyEnvVar
    }
}

extension Config.Vad {
    private enum CodingKeys: String, CodingKey {
        case silenceThresholdDb, minSpeechSec, splitAfterSilenceSec, minSegmentSec, maxSegmentSec, paddingSec, autoStopAfterSilenceSec
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        silenceThresholdDb = try c.decodeIfPresent(Double.self, forKey: .silenceThresholdDb) ?? silenceThresholdDb
        minSpeechSec = try c.decodeIfPresent(Double.self, forKey: .minSpeechSec) ?? minSpeechSec
        splitAfterSilenceSec = try c.decodeIfPresent(Double.self, forKey: .splitAfterSilenceSec) ?? splitAfterSilenceSec
        minSegmentSec = try c.decodeIfPresent(Double.self, forKey: .minSegmentSec) ?? minSegmentSec
        maxSegmentSec = try c.decodeIfPresent(Double.self, forKey: .maxSegmentSec) ?? maxSegmentSec
        paddingSec = try c.decodeIfPresent(Double.self, forKey: .paddingSec) ?? paddingSec
        autoStopAfterSilenceSec = try c.decodeIfPresent(Double.self, forKey: .autoStopAfterSilenceSec) ?? autoStopAfterSilenceSec
    }
}

extension Config.Audio {
    private enum CodingKeys: String, CodingKey { case inputDeviceUID, inputDeviceName }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? inputDeviceUID
        inputDeviceName = try c.decodeIfPresent(String.self, forKey: .inputDeviceName) ?? inputDeviceName
    }
}

extension Config.UI {
    private enum CodingKeys: String, CodingKey { case overlayPosition, sounds }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlayPosition = try c.decodeIfPresent(String.self, forKey: .overlayPosition) ?? overlayPosition
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
    }
}

extension Config.Hotkey {
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int.self, forKey: .keyCode) ?? keyCode
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? modifiers
    }
}
