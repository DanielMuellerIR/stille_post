import Foundation
import StillePostCore
import StillePostCLITerminal

/// Diagnose nach stderr — stdout bleibt sauber für das eigentliche Ergebnis,
/// damit man die Ausgabe gefahrlos weiterverarbeiten kann (Pipes, Skripte).
@discardableResult
private func log(_ message: String) -> Bool {
    do {
        try FileHandle.standardError.write(contentsOf: Data("stillepost-cli: \(message)\n".utf8))
        return true
    } catch {
        return false
    }
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    log(message)
    exit(code)
}

/// Kleiner thread-sicherer Wert. Gebraucht für die Fortschrittsanzeige des
/// Modell-Downloads: Der Callback kommt aus dem URLSession-Task, nicht vom
/// Main-Thread, soll aber mitzählen, welche Prozentzahl zuletzt zu sehen war.
private final class Atomic<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Prüft die vollständige Befehlsform, bevor schon `Config.load()` bei einer
/// fehlenden Konfiguration eine Datei anlegt. Vor allem dürfen vertippte Optionen
/// weder Verlauf löschen noch Schlüsselbund, Netz oder Server berühren.
private func argumentsAreValid(_ arguments: [String]) -> Bool {
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

/// Headless-Kommandozeile von Stille Post.
///
/// Damit lässt sich die komplette Pipeline OHNE GUI nutzen und testen — auch von
/// Skripten und Automatisierung aus (maschinenlesbare Ausgabe, definierte Exitcodes):
///
///   stillepost-cli doctor                  # prüft whisper-server, Modell, Ollama, Cleanup-Provider
///   stillepost-cli install-model           # Whisper-Modell laden (Default: large-v3-turbo)
///   stillepost-cli transcribe datei.wav    # WAV -> Transkription + Bereinigung -> stdout
///   stillepost-cli transcribe datei.wav --raw    # ohne Bereinigung
///   stillepost-cli cleanup "roher text"    # nur die Textbereinigung
///   stillepost-cli cleanup -               # UTF-8 von stdin (bis 1 MiB)
///   stillepost-cli history list [--json]   # Verlauf anzeigen
///   stillepost-cli history clear           # Verlauf + zurückbehaltene Aufnahmen löschen
///   stillepost-cli bridge status           # Netzwerk-Brücke: Zustand, Adresse, Grenzen
///   stillepost-cli bridge token [--new]    # Zugangs-Token in die Zwischenablage (--reveal: nach stdout)
///   stillepost-cli bridge serve            # Brücke im Vordergrund betreiben (Diagnose)
///   stillepost-cli set-cleanup-key         # API-Key für Cloud-Bereinigung in den Schlüsselbund (von stdin!)
///
/// Exit-Codes: 0 = ok, 1 = Fehler, 2 = Bedienungsfehler (Argumente oder Eingabe).
@main
enum StillePostCLI {
    static func main() async {
        let usage = L10n.text("cli.usage")
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(usage)
            exit(2)
        }
        guard argumentsAreValid(arguments) else { fail(usage, code: 2) }

        do {
            let config = try (command == "doctor" ? ConfigFile().loadSnapshot() : Config.load()).resolvedForRequest()
            try await run(command, arguments: arguments, config: config)
        } catch {
            fail(L10n.format("cli.error", error.localizedDescription))
        }
    }
}

private func run(_ command: String, arguments: [String], config: Config) async throws {
    switch command {

    // MARK: doctor — alle Abhängigkeiten prüfen
    case "doctor":
        let report = try await DiagnosticsService().scan(configuration: config)
        for finding in report.findings {
            let mark: String
            switch finding.level {
            case .ready: mark = "✓"
            case .problem: mark = "✗"
            case .warning: mark = "!"
            case .unknown: mark = "?"
            case .information: mark = "·"
            }
            print(mark + " " + finding.message)
        }
        if report.problemCount > 0 {
            print(L10n.format(report.problemCount == 1 ? "cli.doctor.problems.one" : "cli.doctor.problems.other", report.problemCount))
        } else if report.findings.contains(where: { $0.level == .warning || $0.level == .unknown }) {
            print(L10n.text("diagnosis.checked"))
        } else { print(L10n.text("cli.doctor.ready")) }
        exit(report.problemCount == 0 ? 0 : 1)

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
        let interactive = isatty(STDERR_FILENO) == 1
        let installer = ModelInstaller()
        let lastShownPercent = Atomic(-1)
        do {
            let finalPath = try await installer.install(model, to: targetPath) { progress in
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
            let text = try await transcribe(wavPath, rawOnly: rawOnly, config: config)
            print(text)
        } catch {
            fail(L10n.format("cli.error", error.localizedDescription))
        }

    // MARK: cleanup — nur die Textbereinigung
    case "cleanup":
        let input = arguments[1] == "-" ? try readCleanupInput() : arguments[1]
        let started = Date()
        let result = await CleanupService(config: config.cleanup).clean(input)
        log(L10n.format(
            "cli.cleanup.timing",
            Date().timeIntervalSince(started),
            result.endpoint ?? L10n.text("editor.origin.\(result.origin.rawValue)")
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
                // Von der Mac-Zwischenablage kommt das Token per Handoff aufs iPhone.
                do {
                    try copyBridgeToken(token)
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
                try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
                    server.start { started.resume(with: $0) }
                }
            } catch {
                fail(L10n.format("cli.error", error.localizedDescription))
            }
            log(L10n.format("cli.bridge.serving", bridgeBaseURL()))
            // Der asynchrone Einstieg hält den Haupt-Executor bereits am Leben,
            // während der Server bis zum Prozessende auf seiner eigenen Queue arbeitet.
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            withExtendedLifetime(server) {}

        default:
            fail(L10n.text("cli.usage"), code: 2)
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
                    let preview = entry.cleanText.isEmpty ? (entry.diagnosticMessage ?? "") : String(entry.cleanText.prefix(80))
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
            fail(L10n.text("cli.usage"), code: 2)
        }

    // MARK: set-cleanup-key — API-Key sicher in den Schlüsselbund
    case "set-cleanup-key":
        // Der Key wird bewusst NUR von stdin gelesen: Als Argument würde er in der
        // Shell-History und in Prozesslisten landen.
        let typedLine = readCleanupKey()
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
        fail(L10n.text("cli.usage"), code: 2)
    }
}

private func transcribe(_ wavPath: String, rawOnly: Bool, config: Config) async throws -> String {
    let whisperClient = WhisperClient(config: config.whisper)
    let serverManager = WhisperServerManager(config: config.whisper)
    // Scope-Besitz: Nur ein von diesem Manager gestarteter Kindprozess wird
    // beendet; ein bereits laufender fremder Server bleibt unangetastet.
    defer { serverManager.stop() }
    try await serverManager.ensureRunning(client: whisperClient)
    let started = Date()
    let raw = try await whisperClient.transcribe(wavFile: URL(fileURLWithPath: wavPath))
    log(String(format: "STT: %.2f s", Date().timeIntervalSince(started)))
    if rawOnly || (!config.cleanup.enabled && !config.cleanup.spokenFormatting) { return raw }
    let cleanupStarted = Date()
    let result = await CleanupService(config: config.cleanup).clean(raw)
    let suffix = result.usedFallback
        ? L10n.format("cli.cleanup.raw_fallback_suffix", result.fallbackReason ?? "?")
        : ""
    log(L10n.format(
        "cli.cleanup.timing_with_suffix",
        Date().timeIntervalSince(cleanupStarted),
        result.endpoint ?? L10n.text("editor.origin.\(result.origin.rawValue)"),
        suffix
    ))
    return result.text
}

private func readCleanupInput() throws -> String {
    let byteLimit = 1_048_576
    let chunkSize = 64 * 1024
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: min(chunkSize, byteLimit - data.count + 1)),
          !chunk.isEmpty {
        guard chunk.count <= byteLimit - data.count else {
            fail(L10n.format("cli.cleanup.stdin_too_large", byteLimit), code: 2)
        }
        data.append(chunk)
    }
    guard let input = String(data: data, encoding: .utf8) else {
        fail(L10n.text("cli.cleanup.stdin_invalid_utf8"), code: 2)
    }
    return input
}

private func readCleanupKey() -> String? {
    #if DEBUG
    // Deterministischer Fehlerpfad für den CLI-Vertragstest. Auch dabei wird
    // abgebrochen, bevor die Schlüsseleingabe gelesen wird.
    if ProcessInfo.processInfo.environment["STILLEPOST_TEST_TERMINAL_ECHO_FAILURE"] == "1" {
        fail(L10n.text("cli.key.echo_failed"))
    }
    #endif

    var settings = termios()
    return withUnsafeMutablePointer(to: &settings) { settings in
        let echo = sp_terminal_disable_echo(settings)
        guard echo != SP_TERMINAL_ECHO_FAILED else {
            fail(L10n.text("cli.key.echo_failed"))
        }
        let promptWritten = log(L10n.text("cli.key.prompt"))
        let input = promptWritten ? readLine(strippingNewline: true) : nil
        if echo == SP_TERMINAL_ECHO_DISABLED {
            guard sp_terminal_restore_echo() == 0 else {
                fail(L10n.text("cli.key.echo_restore_failed"))
            }
            // Das abschließende Enter wurde ebenfalls nicht angezeigt.
            if promptWritten { try? FileHandle.standardError.write(contentsOf: Data("\n".utf8)) }
        }
        guard promptWritten else { exit(1) }
        return input
    }
}

private enum ClipboardProcessError: LocalizedError {
    case exit(Int32)
    case signal(Int32)

    var errorDescription: String? {
        switch self {
        case .exit(let status): return L10n.format("cli.bridge.token_copy_exit", status)
        case .signal(let signal): return L10n.format("cli.bridge.token_copy_signal", signal)
        }
    }
}

private func copyBridgeToken(_ token: String) throws {
    // Das Token bleibt durch die Pipe aus der Prozessliste. Beendet sich
    // pbcopy vor der Übertragung, soll EPIPE als Fehler ankommen.
    let copy = Process()
    copy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    copy.standardInput = pipe
    let writer = pipe.fileHandleForWriting
    guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    try copy.run()
    let delivery = Result {
        defer { try? writer.close() }
        try writer.write(contentsOf: Data(token.utf8))
    }
    copy.waitUntilExit()
    guard copy.terminationReason == .exit else {
        throw ClipboardProcessError.signal(copy.terminationStatus)
    }
    guard copy.terminationStatus == 0 else {
        throw ClipboardProcessError.exit(copy.terminationStatus)
    }
    try delivery.get()
}
