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
///   stillepost-cli bridge status           # Netzwerk-Brücke: Zustand, Adresse, Grenzen
///   stillepost-cli bridge token [--new]    # Zugangs-Token in die Zwischenablage (--reveal: nach stdout)
///   stillepost-cli bridge serve            # Brücke im Vordergrund betreiben (Diagnose)
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

/// Schaltet die Anzeige der Tastatureingabe im Terminal ab und wieder an.
///
/// `readLine` kann das nicht: Es liest nur, das Anzeigen macht das Terminal
/// selbst. Ohne diesen Schalter steht ein eingetippter API-Schlüssel sichtbar im
/// Fenster und bleibt im Scrollback stehen — obwohl die Aufforderung davor
/// ausdrücklich verspricht, dass die Eingabe nicht angezeigt wird. Kommt die
/// Eingabe aus einer Pipe, gibt es kein Terminal und nichts abzuschalten.
enum TerminalEcho {
    enum DisableResult {
        case notTTY
        case disabled
        case failed
    }

    /// Die Terminal-Einstellungen VOR dem Abschalten. `nil` = nichts verändert.
    private static var saved: termios?

    @discardableResult
    static func disable() -> DisableResult {
        // Deterministischer Fehlerpfad für den CLI-Vertragstest. Er kann nur
        // sicher abbrechen und niemals eine Schlüsseleingabe sichtbar machen.
        if ProcessInfo.processInfo.environment["STILLEPOST_TEST_TERMINAL_ECHO_FAILURE"] == "1" {
            return .failed
        }
        guard isatty(STDIN_FILENO) == 1 else { return .notTTY }
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else { return .failed }
        saved = settings
        // Bricht der Nutzer mitten in der Eingabe ab (Ctrl-C) oder wird der
        // Prozess beendet, stirbt er mit stummgeschaltetem Terminal — der
        // Handler stellt es vorher wieder her. Die Handler stehen schon VOR dem
        // Abschalten: So bleibt auch das winzige Fenster während `tcsetattr`
        // abgesichert.
        signal(SIGINT) { _ in
            TerminalEcho.restore()
            _exit(130)
        }
        signal(SIGTERM) { _ in
            TerminalEcho.restore()
            _exit(143)
        }
        settings.c_lflag &= ~tcflag_t(ECHO)
        // TCSAFLUSH: erst alles Getippte verwerfen, dann umschalten — sonst
        // könnte schon vorher Eingetipptes noch sichtbar durchrutschen.
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &settings) == 0 else {
            // `saved` darf nur bedeuten, dass die Anzeige wirklich aus ist.
            // Zugleich die eben installierten Signal-Handler zurücknehmen.
            restore()
            return .failed
        }
        return .disabled
    }

    static func restore() {
        guard var previous = saved else { return }
        saved = nil
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &previous)
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

let usage = L10n.text("cli.usage")

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(2)
}

/// Prüft die vollständige Befehlsform, bevor schon `Config.load()` bei einer
/// fehlenden Konfiguration eine Datei anlegt. Vor allem dürfen vertippte Optionen
/// weder Verlauf löschen noch Schlüsselbund, Netz oder Server berühren.
func argumentsAreValid(_ arguments: [String]) -> Bool {
    guard let command = arguments.first else { return false }
    switch command {
    case "doctor", "set-cleanup-key":
        return arguments.count == 1
    case "install-model":
        let supplied = Array(arguments.dropFirst())
        let models = supplied.filter { !$0.hasPrefix("--") }
        let options = supplied.filter { $0.hasPrefix("--") }
        return models.count <= 1
            && options.allSatisfy { $0 == "--force" }
            && options.filter { $0 == "--force" }.count <= 1
    case "transcribe":
        return arguments.count == 2
            || (arguments.count == 3 && arguments[2] == "--raw")
    case "cleanup":
        return arguments.count == 2
    case "bridge":
        guard arguments.count >= 2 else { return false }
        switch arguments[1] {
        case "status", "serve":
            return arguments.count == 2
        case "token":
            let options = Array(arguments.dropFirst(2))
            return options.count <= 2
                && Set(options).count == options.count
                && options.allSatisfy { $0 == "--new" || $0 == "--reveal" }
        default:
            return false
        }
    case "history":
        guard arguments.count >= 2 else { return false }
        switch arguments[1] {
        case "list":
            let options = Array(arguments.dropFirst(2))
            return options.isEmpty || options == ["--json"]
        case "clear":
            return arguments.count == 2
        default:
            return false
        }
    default:
        return false
    }
}

guard argumentsAreValid(arguments) else { fail(usage, code: 2) }

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

    // Reihenfolge wie in `WhisperServerManager.ensureRunning`, und das ist keine
    // Kosmetik: Dort zählt zuerst, ob der Server ANTWORTET. Tut er das, braucht
    // Stille Post weder Binary noch Modelldatei — fehlende Startdateien sind dann
    // kein Problem, sondern ein Hinweis für den nächsten Kaltstart. Läuft er
    // dagegen nicht und ist der Selbststart aus, scheitert jede Transkription,
    // auch wenn alle Dateien da sind. Vorher urteilte `doctor` genau andersherum
    // und lieferte in beiden Lagen den falschen Exit-Code.
    var serverReachable = false
    if whisperEndpoint != nil {
        serverReachable = try runBlocking { await whisperClient.isReachable() }
        if serverReachable {
            print(L10n.format("cli.doctor.server_running", config.whisper.serverURL))
        } else if config.whisper.autostart {
            print(L10n.text("cli.doctor.server_stopped"))
        } else {
            problems += 1
            print(L10n.format("cli.doctor.server_stopped_no_autostart",
                              config.whisper.serverURL))
        }
    }

    // whisper-server-Binary + Modell-Datei braucht nur der Selbststart. Ist der
    // Server aus UND autostart abgeschaltet, hat `doctor` den aktiven Blocker
    // oben bereits genau einmal gemeldet; unbenutzte Startdateien wären keine
    // weiteren Probleme. Bei einem laufenden Server zeigen wir ihren Zustand
    // weiterhin als Hinweis für einen möglichen späteren Kaltstart.
    if config.whisper.autostart || serverReachable {
        let startFilesNeeded = !serverReachable
        var startFilesComplete = true
        let binary = Config.expandPath(config.whisper.binaryPath)
        if FileManager.default.isExecutableFile(atPath: binary) {
            print(L10n.format("cli.doctor.binary_ok", binary))
        } else {
            startFilesComplete = false
            if startFilesNeeded { problems += 1 }
            print(L10n.format("cli.doctor.binary_missing", binary))
        }
        // Bewusst über den Zustandsbegriff statt `fileExists`: Letzteres folgt
        // Symlinks und meldet auch dann "✓ Modell da", wenn hier nur ein Verweis
        // auf einen fremden Cache liegt — dann ist das Modell weg, sobald das
        // fremde Programm aufräumt.
        switch ModelInstaller.state(atPath: config.whisper.modelPath) {
        case .installed(let path, let bytes):
            print(L10n.format("cli.doctor.model_ok", path, ByteSize.megabytes(bytes)))
        case .borrowed(let path, let target):
            startFilesComplete = false
            if startFilesNeeded { problems += 1 }
            print(L10n.format("cli.doctor.model_borrowed", path))
            print(L10n.format("cli.doctor.model_target", target))
            print(L10n.text("cli.doctor.model_borrowed_help"))
            print("  stillepost-cli install-model")
        case .missing(let path):
            startFilesComplete = false
            if startFilesNeeded { problems += 1 }
            print(L10n.format("cli.doctor.model_missing", path))
            print(L10n.text("cli.doctor.model_download_help"))
        }
        if !startFilesComplete && !startFilesNeeded {
            print(L10n.text("cli.doctor.start_files_unused"))
        }
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
        // Ein Dienst für die ganze Kette: Er trägt keinen Zustand je Endpunkt,
        // die zu prüfende Adresse kommt bei jedem Aufruf mit.
        let cleanupService = CleanupService(config: config.cleanup)
        /// Prüft einen einzelnen Bereinigungs-Endpoint; true = benutzbar.
        func checkEndpoint(_ endpoint: Config.Cleanup.Endpoint, name: String) -> Bool {
            if endpoint.provider == "openai" {
                let remote = endpoint.remote
                // Dieselbe Prüfung, die auch die Bereinigung fährt: Sie baut die
                // Adresse genauso. Ein nichtleerer, aber unbrauchbarer Wert wie
                // `http://[` galt hier früher als eingerichtet — und jedes Diktat
                // fiel danach still auf den Rohtext zurück.
                if CleanupService.remoteChatURL(remote) == nil {
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
            // Ollama erreichbar + Modell vorhanden? Die Prüfung liegt im Kern:
            // Adressbau, Zeitgrenze und die Namensregel für Modell-Tags sind
            // dieselben, nach denen die Bereinigung später arbeitet. Früher
            // sprach `doctor` hier selbst HTTP und konnte deshalb „alles gut“
            // melden, während `clean()` nach anderen Regeln scheiterte.
            switch (try? runBlocking { await cleanupService.checkOllamaEndpoint(endpoint) })
                ?? .unreachable {
            case .ready:
                print(L10n.format("cli.doctor.cleanup_ollama_ok", name, endpoint.label))
                return true
            case .modelMissing:
                print(L10n.format(
                    "cli.doctor.cleanup_model_missing",
                    name,
                    endpoint.model,
                    endpoint.model
                ))
                return false
            case .unreachable:
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
    let installArguments = Array(arguments.dropFirst())
    let modelArguments = installArguments.filter { !$0.hasPrefix("--") }
    let modelName = modelArguments.first ?? ModelCatalog.turbo.name
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
    let wavPath = arguments[1]
    let rawOnly = arguments.contains("--raw")
    guard FileManager.default.fileExists(atPath: wavPath) else {
        fail(L10n.format("cli.file_not_found", wavPath))
    }

    do {
        let text: String = try runBlocking {
            let whisperClient = WhisperClient(config: config.whisper)
            let serverManager = WhisperServerManager(config: config.whisper)
            // Scope-Besitz: Nur ein von diesem Manager gestarteter Kindprozess wird
            // beendet; ein bereits laufender fremder Server bleibt unangetastet.
            defer { serverManager.stop() }
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

// MARK: bridge — Netzwerkzugang für eigene Geräte im Heimnetz
case "bridge":
    /// Adresse, die auf dem iPhone in den Kurzbefehl gehört (siehe BridgeAddress).
    func bridgeBaseURL() -> String { BridgeAddress.baseURL(port: config.bridge.port) }

    switch arguments.dropFirst().first {

    case "status":
        print(config.bridge.enabled
            ? L10n.format("cli.bridge.enabled", String(config.bridge.port))
            : L10n.text("cli.bridge.disabled"))
        switch BridgeToken.loadOutcome() {
        case .token:
            print(L10n.text("cli.bridge.token_present"))
        case .missing:
            print(L10n.text("cli.bridge.token_missing"))
        case .failed(let status):
            // Nicht als „kein Token“ ausgeben: Der Eintrag kann existieren und
            // nur gerade unlesbar sein.
            print(L10n.format("cli.bridge.token_error", String(status)))
        }
        print(L10n.format("cli.bridge.url", bridgeBaseURL()))
        print(L10n.format("cli.bridge.limit", config.bridge.maxRequestMegabytes))

    case "token":
        // Ohne --new bleibt ein vorhandenes Token gültig: Ein neues würde alle
        // schon eingerichteten Geräte aussperren, und das soll niemandem
        // versehentlich passieren.
        let wantsNew = arguments.contains("--new")
        let token: String
        do {
            let resolved = try BridgeToken.resolveForCommand(wantsNew: wantsNew)
            token = resolved.token
            log(L10n.text(resolved.reused
                ? "cli.bridge.token_reused"
                : "cli.bridge.token_created"))
        } catch BridgeToken.LoadError.keychain(let status) {
            // Ein Lesefehler bricht ab, statt ersatzweise ein neues Token
            // anzulegen: Solange unklar ist, ob schon eines im Schlüsselbund
            // liegt, würde das Überschreiben alle Geräte aussperren.
            fail(L10n.format("cli.bridge.token_error", String(status)))
        } catch {
            fail(L10n.format("cli.error", error.localizedDescription))
        }
        if arguments.contains("--reveal") {
            // Ausdrücklich verlangt (für Skripte). Sonst geht das Geheimnis NICHT
            // nach stdout, damit es nicht in Protokollen und Scrollback landet.
            print(token)
        } else {
            // Über stdin an pbcopy — nie als Argument, sonst stünde das Token in
            // der Prozessliste. Von der Mac-Zwischenablage kommt es per Handoff
            // direkt aufs iPhone.
            let copy = Process()
            copy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
            let pipe = Pipe()
            copy.standardInput = pipe
            do {
                try copy.run()
                pipe.fileHandleForWriting.write(Data(token.utf8))
                pipe.fileHandleForWriting.closeFile()
                copy.waitUntilExit()
                log(L10n.text("cli.bridge.token_copied"))
            } catch {
                fail(L10n.format("cli.bridge.token_copy_failed", error.localizedDescription))
            }
        }

    case "serve":
        // Vordergrund-Betrieb für Diagnose und launchd. Im Alltag startet die App
        // die Brücke selbst, sobald sie in den Einstellungen eingeschaltet ist.
        let server = BridgeServer(config: config)
        server.onLog = { message in
            FileHandle.standardError.write(Data("stillepost-cli: \(message)\n".utf8))
        }
        do {
            try server.start()
        } catch {
            fail(L10n.format("cli.error", error.localizedDescription))
        }
        log(L10n.format("cli.bridge.serving", bridgeBaseURL()))
        dispatchMain()

    default:
        fail(usage, code: 2)
    }

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
    let echoResult = TerminalEcho.disable()
    guard echoResult != .failed else {
        // Das Sicherheitsversprechen ist wichtiger als eine Eingabe mit
        // möglicherweise sichtbarem Schlüssel: vor `readLine` abbrechen.
        fail(L10n.text("cli.key.echo_failed"))
    }
    let typedLine = readLine(strippingNewline: true)
    let inputWasHidden = echoResult == .disabled
    TerminalEcho.restore()
    // Das abschließende Enter war ebenfalls nicht zu sehen; ohne diesen
    // Zeilenumbruch klebte die nächste Meldung hinter der Eingabeaufforderung.
    if inputWasHidden { FileHandle.standardError.write(Data("\n".utf8)) }
    guard let line = typedLine, !line.isEmpty else {
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
