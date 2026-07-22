import Foundation
import StillePostCore

/// Headless-Kommandozeile von Stille Post.
///
/// Damit lässt sich die komplette Pipeline OHNE GUI nutzen und testen — auch von
/// Skripten und AI-Agenten aus (maschinenlesbarer Output, saubere Exit-Codes):
///
///   stillepost-cli doctor                  # prüft whisper-server, Modell, Ollama, Cleanup-Provider
///   stillepost-cli install-model           # Whisper-Modell laden (Default: large-v3-turbo)
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

/// Kleiner thread-sicherer Wert. Gebraucht für die Fortschrittsanzeige des
/// Modell-Downloads: Der Callback kommt aus dem URLSession-Task, nicht vom
/// Main-Thread, soll aber mitzählen, welche Prozentzahl zuletzt zu sehen war.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

let usage = L10n.text("cli.usage")

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
    let whisperEndpoint: WhisperEndpoint?
    do {
        whisperEndpoint = try WhisperEndpoint(serverURL: config.whisper.serverURL)
    } catch {
        whisperEndpoint = nil
        problems += 1
        print(L10n.format("cli.doctor.server_invalid", error.localizedDescription))
    }

    // whisper-server-Binary + Modell-Datei
    let binary = Config.expandPath(config.whisper.binaryPath)
    print(FileManager.default.isExecutableFile(atPath: binary)
        ? L10n.format("cli.doctor.binary_ok", binary)
        : {
            problems += 1
            return L10n.format("cli.doctor.binary_missing", binary)
        }())
    // Bewusst über den Zustandsbegriff statt `fileExists`: Letzteres folgt Symlinks
    // und meldet auch dann "✓ Modell da", wenn hier nur ein Verweis auf einen
    // fremden Cache liegt — dann ist das Modell weg, sobald das fremde Programm
    // aufräumt.
    switch ModelInstaller.state(atPath: config.whisper.modelPath) {
    case .installed(let path, let bytes):
        print(L10n.format("cli.doctor.model_ok", path, ByteSize.megabytes(bytes)))
    case .borrowed(let path, let target):
        problems += 1
        print(L10n.format("cli.doctor.model_borrowed", path))
        print(L10n.format("cli.doctor.model_target", target))
        print(L10n.text("cli.doctor.model_borrowed_help"))
        print("  stillepost-cli install-model")
    case .missing(let path):
        problems += 1
        print(L10n.format("cli.doctor.model_missing", path))
        print(L10n.text("cli.doctor.model_download_help"))
    }

    // Läuft der Server? (Falls nicht: kein Fehler — die App startet ihn selbst.)
    if whisperEndpoint != nil {
        let reachable = try runBlocking { await whisperClient.isReachable() }
        print(reachable
            ? L10n.format("cli.doctor.server_running", config.whisper.serverURL)
            : L10n.text("cli.doctor.server_stopped"))
    }

    // Häufigster Anfänger-Stolperstein: language=auto rät die Sprache pro
    // Sprech-Segment und ÜBERSETZT bei Fehl-Erkennung ungefragt.
    if config.whisper.language == "auto" {
        print(L10n.text("cli.doctor.language_auto"))
    }

    // Bereinigung: jeden Endpoint der Kette prüfen (primär + Fallbacks).
    // Ein toter Endpoint ist erst dann ein hartes Problem, wenn die GANZE Kette
    // tot ist — genau dafür gibt es die Fallbacks ja.
    if !config.cleanup.enabled {
        print(L10n.text("cli.doctor.cleanup_off"))
    } else {
        /// Prüft einen einzelnen Bereinigungs-Endpoint; true = benutzbar.
        func checkEndpoint(_ endpoint: Config.Cleanup.Endpoint, name: String) -> Bool {
            if endpoint.provider == "openai" {
                let remote = endpoint.remote
                if remote.baseURL.isEmpty || remote.model.isEmpty {
                    print(L10n.format("cli.doctor.cleanup_remote_config", name))
                    return false
                }
                if CleanupService.remoteAPIKey(envVar: remote.apiKeyEnvVar) == nil {
                    print(L10n.format("cli.doctor.cleanup_no_key", name, remote.apiKeyEnvVar))
                    return false
                }
                print(L10n.format("cli.doctor.cleanup_cloud_ok", name, endpoint.label))
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
                    print(L10n.format("cli.doctor.cleanup_ollama_ok", name, endpoint.label))
                    return true
                }
                print(L10n.format(
                    "cli.doctor.cleanup_model_missing",
                    name,
                    endpoint.model,
                    endpoint.model
                ))
                return false
            } catch {
                print(L10n.format("cli.doctor.cleanup_unreachable", name, endpoint.ollamaURL))
                return false
            }
        }
        let chain = config.cleanup.chain
        var usable = 0
        for (index, endpoint) in chain.enumerated() {
            let name = index == 0
                ? L10n.text("cli.doctor.primary")
                : L10n.format("settings.cleanup.fallback_number", index)
            if checkEndpoint(endpoint, name: name) { usable += 1 }
        }
        if usable == 0 {
            problems += 1
            print(L10n.text("cli.doctor.no_cleanup"))
        }
    }

    print(problems == 0
        ? L10n.text("cli.doctor.ready")
        : L10n.format(
            problems == 1 ? "cli.doctor.problems.one" : "cli.doctor.problems.other",
            problems
        ))
    exit(problems == 0 ? 0 : 1)

// MARK: install-model — Whisper-Modell selbst beschaffen
case "install-model":
    let modelName = arguments.dropFirst().first { !$0.hasPrefix("--") } ?? ModelCatalog.turbo.name
    guard let model = ModelCatalog.model(named: modelName) else {
        let known = ModelCatalog.offered.map(\.name).joined(separator: ", ")
        fail(L10n.format("cli.model.unknown", modelName, known), code: 2)
    }
    let force = arguments.contains("--force")
    let targetPath = config.whisper.modelPath

    // Schon da? Dann nichts tun — der Befehl ist damit gefahrlos wiederholbar
    // (z. B. aus einem Setup-Skript).
    if case .installed(let path, let bytes) = ModelInstaller.state(atPath: targetPath), !force {
        print(L10n.format("cli.model.already_installed", path, ByteSize.megabytes(bytes)))
        exit(0)
    }
    if case .borrowed(let path, let target) = ModelInstaller.state(atPath: targetPath) {
        log(L10n.format("cli.model.borrowed_notice", path, target))
        log(L10n.text("cli.model.borrowed_replace"))
    }

    log(L10n.format("cli.model.downloading", model.name, model.approximateMegabytes))
    // Fortschritt nach stderr, damit stdout für das Ergebnis sauber bleibt. Nur bei
    // einem Terminal die Zeile überschreiben — in eine Datei oder Pipe geloggt wäre
    // ein Wagenrücklauf-Gewitter unlesbar.
    let interactive = isatty(fileno(stderr)) == 1
    let installer = ModelInstaller()
    let lastShownPercent = Atomic(-1)
    do {
        let finalPath = try runBlocking {
            try await installer.install(model, to: targetPath) { progress in
                guard let percent = progress.percent else { return }
                guard percent > lastShownPercent.value else { return }
                lastShownPercent.value = percent
                let line = L10n.format(
                    "cli.model.progress",
                    percent,
                    progress.receivedMegabytes,
                    progress.totalMegabytes
                )
                FileHandle.standardError.write(Data((interactive ? "\r\(line)   " : line + "\n").utf8))
            }
        }
        if interactive { FileHandle.standardError.write(Data("\n".utf8)) }
        print(finalPath)
        exit(0)
    } catch {
        if interactive { FileHandle.standardError.write(Data("\n".utf8)) }
        fail("\(error.localizedDescription)")
    }

// MARK: transcribe — WAV-Datei durch die Pipeline schicken
case "transcribe":
    guard arguments.count >= 2 else { fail(usage, code: 2) }
    let wavPath = arguments[1]
    let rawOnly = arguments.contains("--raw")
    guard FileManager.default.fileExists(atPath: wavPath) else {
        fail(L10n.format("cli.file_not_found", wavPath))
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
            let suffix = result.usedFallback
                ? L10n.format("cli.cleanup.raw_fallback_suffix", result.fallbackReason ?? "?")
                : ""
            log(L10n.format(
                "cli.cleanup.timing_with_suffix",
                Date().timeIntervalSince(cleanupStarted),
                result.endpoint ?? "—",
                suffix
            ))
            return result.text
        }
        print(text)
    } catch {
        fail(L10n.format("cli.error", error.localizedDescription))
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
    log(L10n.format(
        "cli.cleanup.timing",
        Date().timeIntervalSince(started),
        result.endpoint ?? "—"
    ))
    if result.usedFallback {
        log(L10n.format("cli.cleanup.raw_fallback", result.fallbackReason ?? "?"))
    }
    print(result.text)

// MARK: history — Verlauf anzeigen/löschen
case "history":
    let store = HistoryStore()
    switch arguments.dropFirst().first {
    case "list":
        let entries: [HistoryStore.Entry]
        do {
            entries = try store.list()
        } catch {
            fail(L10n.format("cli.history.persistence_failed", error.localizedDescription))
        }
        if arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(entries), encoding: .utf8) ?? "[]")
        } else {
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                let status = entry.isFailed ? L10n.text("cli.history.failed") : "ok"
                let preview = entry.cleanText.isEmpty ? (entry.errorMessage ?? "") : String(entry.cleanText.prefix(80))
                // Diagnose: Bereinigungsdauer + Endpoint (zeigt Fallback-Nutzung).
                var cleanupInfo = ""
                if let sec = entry.cleanupSec, let endpoint = entry.cleanupEndpoint {
                    cleanupInfo = L10n.format("cli.history.cleanup_info", sec, endpoint)
                }
                print("\(formatter.string(from: entry.date))  [\(status)]  \(preview)\(cleanupInfo)")
            }
            if entries.isEmpty { log(L10n.text("cli.history.empty")) }
        }
    case "clear":
        do {
            try store.deleteAll()
        } catch {
            fail(L10n.format("cli.history.persistence_failed", error.localizedDescription))
        }
        log(L10n.text("cli.history.cleared"))
    default:
        fail(usage, code: 2)
    }

// MARK: set-cleanup-key — API-Key sicher in den Schlüsselbund
case "set-cleanup-key":
    // Der Key wird bewusst NUR von stdin gelesen: Als Argument würde er in der
    // Shell-History und in Prozesslisten landen.
    log(L10n.text("cli.key.prompt"))
    guard let line = readLine(strippingNewline: true), !line.isEmpty else {
        fail(L10n.text("cli.key.empty"), code: 2)
    }
    do {
        try CleanupService.storeRemoteAPIKey(line)
        log(L10n.format("cli.key.saved", CleanupService.keychainService))
    } catch {
        fail(L10n.format("cli.key.save_failed", error.localizedDescription))
    }

default:
    print(usage)
    exit(2)
}
