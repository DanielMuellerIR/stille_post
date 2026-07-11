import Foundation
import StillePostCore

/// Headless-Kommandozeile von Stille Post.
///
/// Damit lässt sich die komplette Pipeline OHNE GUI nutzen und testen — auch von
/// Skripten und AI-Agenten aus (maschinenlesbarer Output, saubere Exit-Codes):
///
///   stillepost-cli doctor                  # prüft whisper-server, Modell, Ollama, Cleanup-Provider
///   stillepost-cli transcribe datei.wav    # WAV -> Transkription + Bereinigung -> stdout
///   stillepost-cli transcribe datei.wav --raw    # ohne Bereinigung
///   stillepost-cli cleanup "roher text"    # nur die Textbereinigung
///   stillepost-cli cleanup -               # Text von stdin (für Pipes)
///   stillepost-cli history list [--json]   # Verlauf anzeigen
///   stillepost-cli history clear           # Verlauf + zurückbehaltene Aufnahmen löschen
///   stillepost-cli set-cleanup-key         # API-Key für Cloud-Bereinigung in den Schlüsselbund (von stdin!)
///
/// Exit-Codes: 0 = ok, 1 = Fehler, 2 = Bedienungsfehler (falsche Argumente).

/// Diagnose nach stderr — stdout bleibt sauber für das eigentliche Ergebnis,
/// damit man die Ausgabe gefahrlos weiterverarbeiten kann (Pipes, Skripte).
func log(_ message: String) {
    FileHandle.standardError.write(Data("stillepost-cli: \(message)\n".utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    log(message)
    exit(code)
}

let usage = """
Verwendung:
  stillepost-cli doctor
  stillepost-cli transcribe <datei.wav> [--raw]
  stillepost-cli cleanup <text|->
  stillepost-cli history list [--json]
  stillepost-cli history clear
  stillepost-cli set-cleanup-key   (liest den Key von stdin — NIE als Argument übergeben!)
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

let config = Config.load()

/// Blockierender Brücken-Helfer: führt async-Code in einem synchronen CLI-Programm aus.
func runBlocking<T>(_ work: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do { result = .success(try await work()) }
        catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
}

switch command {

// MARK: doctor — alle Abhängigkeiten prüfen
case "doctor":
    var problems = 0
    let whisperClient = WhisperClient(config: config.whisper)

    // whisper-server-Binary + Modell-Datei
    let binary = Config.expandPath(config.whisper.binaryPath)
    print(FileManager.default.isExecutableFile(atPath: binary)
        ? "✓ whisper-server-Binary: \(binary)"
        : { problems += 1; return "✗ whisper-server-Binary fehlt: \(binary) (brew install whisper-cpp)" }())
    let model = Config.expandPath(config.whisper.modelPath)
    print(FileManager.default.fileExists(atPath: model)
        ? "✓ Whisper-Modell: \(model)"
        : { problems += 1; return "✗ Whisper-Modell fehlt: \(model) (scripts/install-model.sh)" }())

    // Läuft der Server? (Falls nicht: kein Fehler — die App startet ihn selbst.)
    let reachable = try runBlocking { await whisperClient.isReachable() }
    print(reachable
        ? "✓ whisper-server läuft: \(config.whisper.serverURL)"
        : "· whisper-server läuft nicht (wird bei Bedarf automatisch gestartet)")

    // Häufigster Anfänger-Stolperstein: language=auto rät die Sprache pro
    // Sprech-Segment und ÜBERSETZT bei Fehl-Erkennung ungefragt.
    if config.whisper.language == "auto" {
        print("· Hinweis: whisper.language steht auf \"auto\" — Empfehlung: feste Sprache setzen (z. B. \"de\"), sonst übersetzt Whisper bei Fehl-Erkennung ungefragt")
    }

    // Bereinigung: jeden Endpoint der Kette prüfen (primär + Fallbacks).
    // Ein toter Endpoint ist erst dann ein hartes Problem, wenn die GANZE Kette
    // tot ist — genau dafür gibt es die Fallbacks ja.
    if !config.cleanup.enabled {
        print("· Textbereinigung: ausgeschaltet")
    } else {
        /// Prüft einen einzelnen Bereinigungs-Endpoint; true = benutzbar.
        func checkEndpoint(_ endpoint: Config.Cleanup.Endpoint, name: String) -> Bool {
            if endpoint.provider == "openai" {
                let remote = endpoint.remote
                if remote.baseURL.isEmpty || remote.model.isEmpty {
                    print("✗ Bereinigung (\(name)): remote.baseURL/model fehlen in config.json")
                    return false
                }
                if CleanupService.remoteAPIKey(envVar: remote.apiKeyEnvVar) == nil {
                    print("✗ Bereinigung (\(name)): kein API-Key (Env \(remote.apiKeyEnvVar) oder Schlüsselbund) — setzen: stillepost-cli set-cleanup-key")
                    return false
                }
                print("✓ Bereinigung (\(name)): Cloud konfiguriert — \(endpoint.label)")
                return true
            }
            // Ollama erreichbar + Modell vorhanden?
            struct TagsResponse: Decodable { struct M: Decodable { let name: String }; let models: [M] }
            do {
                let data = try runBlocking {
                    try await URLSession.shared.data(from: URL(string: "\(endpoint.ollamaURL)/api/tags")!).0
                }
                let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
                if tags.models.contains(where: { $0.name == endpoint.model || $0.name.hasPrefix(endpoint.model + ":") }) {
                    print("✓ Bereinigung (\(name)): Ollama läuft, Modell vorhanden — \(endpoint.label)")
                    return true
                }
                print("✗ Bereinigung (\(name)): Ollama läuft, aber Modell fehlt: \(endpoint.model) (ollama pull \(endpoint.model))")
                return false
            } catch {
                print("✗ Bereinigung (\(name)): Ollama nicht erreichbar — \(endpoint.ollamaURL)")
                return false
            }
        }
        let chain = config.cleanup.chain
        var usable = 0
        for (index, endpoint) in chain.enumerated() {
            let name = index == 0 ? "primär" : "Fallback \(index)"
            if checkEndpoint(endpoint, name: name) { usable += 1 }
        }
        if usable == 0 {
            problems += 1
            print("✗ Kein Bereinigungs-Endpoint benutzbar — Diktate kämen nur roh an")
        }
    }

    print(problems == 0 ? "Alles bereit." : "\(problems) Problem(e) gefunden.")
    exit(problems == 0 ? 0 : 1)

// MARK: transcribe — WAV-Datei durch die Pipeline schicken
case "transcribe":
    guard arguments.count >= 2 else { fail(usage, code: 2) }
    let wavPath = arguments[1]
    let rawOnly = arguments.contains("--raw")
    guard FileManager.default.fileExists(atPath: wavPath) else {
        fail("Datei nicht gefunden: \(wavPath)")
    }

    do {
        let text: String = try runBlocking {
            let whisperClient = WhisperClient(config: config.whisper)
            let serverManager = WhisperServerManager(config: config.whisper)
            try await serverManager.ensureRunning(client: whisperClient)
            let started = Date()
            let raw = try await whisperClient.transcribe(wavFile: URL(fileURLWithPath: wavPath))
            log(String(format: "STT: %.2f s", Date().timeIntervalSince(started)))
            if rawOnly || !config.cleanup.enabled { return raw }
            let cleanupStarted = Date()
            let result = await CleanupService(config: config.cleanup).clean(raw)
            log(String(format: "Bereinigung: %.2f s via %@%@", Date().timeIntervalSince(cleanupStarted),
                       result.endpoint ?? "—",
                       result.usedFallback ? " (Fallback auf Rohtext: \(result.fallbackReason ?? "?"))" : ""))
            return result.text
        }
        print(text)
    } catch {
        fail("Fehler: \(error.localizedDescription)")
    }

// MARK: cleanup — nur die Textbereinigung
case "cleanup":
    guard arguments.count >= 2 else { fail(usage, code: 2) }
    let input: String
    if arguments[1] == "-" {
        input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    } else {
        input = arguments[1]
    }
    let started = Date()
    let result = try runBlocking { await CleanupService(config: config.cleanup).clean(input) }
    log(String(format: "Bereinigung: %.2f s via %@", Date().timeIntervalSince(started), result.endpoint ?? "—"))
    if result.usedFallback {
        log("Fallback auf Rohtext: \(result.fallbackReason ?? "?")")
    }
    print(result.text)

// MARK: history — Verlauf anzeigen/löschen
case "history":
    let store = HistoryStore()
    switch arguments.dropFirst().first {
    case "list":
        let entries = store.list()
        if arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(entries), encoding: .utf8) ?? "[]")
        } else {
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                let status = entry.isFailed ? "FEHLGESCHLAGEN" : "ok"
                let preview = entry.cleanText.isEmpty ? (entry.errorMessage ?? "") : String(entry.cleanText.prefix(80))
                // Diagnose: Bereinigungsdauer + Endpoint (zeigt Fallback-Nutzung).
                var cleanupInfo = ""
                if let sec = entry.cleanupSec, let endpoint = entry.cleanupEndpoint {
                    cleanupInfo = String(format: "  [%.1f s via %@]", sec, endpoint)
                }
                print("\(formatter.string(from: entry.date))  [\(status)]  \(preview)\(cleanupInfo)")
            }
            if entries.isEmpty { log("Verlauf ist leer.") }
        }
    case "clear":
        store.deleteAll()
        log("Verlauf und zurückbehaltene Aufnahmen gelöscht.")
    default:
        fail(usage, code: 2)
    }

// MARK: set-cleanup-key — API-Key sicher in den Schlüsselbund
case "set-cleanup-key":
    // Der Key wird bewusst NUR von stdin gelesen: Als Argument würde er in der
    // Shell-History und in Prozesslisten landen.
    log("API-Key eingeben (Eingabe wird nicht angezeigt, Ende mit Enter):")
    guard let line = readLine(strippingNewline: true), !line.isEmpty else {
        fail("Kein Key eingegeben.", code: 2)
    }
    do {
        try CleanupService.storeRemoteAPIKey(line)
        log("Key im Schlüsselbund gespeichert (Eintrag: \(CleanupService.keychainService)).")
    } catch {
        fail("Speichern fehlgeschlagen: \(error.localizedDescription)")
    }

default:
    print(usage)
    exit(2)
}
