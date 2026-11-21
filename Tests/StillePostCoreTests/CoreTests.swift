import XCTest
import AVFoundation
import AppKit
import Network
@testable import StillePostCore

final class CoreTests: XCTestCase {

    func testPasteboardSnapshotRestoresAllItemsAndHonorsChangeCount() throws {
        let pasteboard = NSPasteboard(name: .init("stillepost-test-\(UUID())"))
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("alter Text", forType: .string)
        first.setData(Data("{\\rtf1 alt}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        let customType = NSPasteboard.PasteboardType("org.stillepost.test-binary")
        second.setData(Data([0, 1, 2, 255]), forType: customType)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Diktat", forType: .string)
        let ownChangeCount = pasteboard.changeCount
        XCTAssertTrue(snapshot.restore(to: pasteboard, ifChangeCountIs: ownChangeCount))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.pasteboardItems?[0].string(forType: .string), "alter Text")
        XCTAssertEqual(pasteboard.pasteboardItems?[0].data(forType: .rtf), Data("{\\rtf1 alt}".utf8))
        XCTAssertEqual(pasteboard.pasteboardItems?[1].data(forType: customType), Data([0, 1, 2, 255]))

        let secondSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("Diktat 2", forType: .string)
        let secondOwnChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("neu kopiert", forType: .string)
        XCTAssertFalse(secondSnapshot.restore(to: pasteboard, ifChangeCountIs: secondOwnChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "neu kopiert")
    }

    // MARK: Deterministische Vorstufe — Zeilenumbruch-Artefakte

    func testFlattenJoinsWordBrokenAcrossLines() {
        // Realer Whisper-Fall: Umbruch mitten im Wort, ohne Leerzeichen.
        XCTAssertEqual(TranscriptPolish.flattenLineBreaks("Identitä\ntsproblem"),
                       "Identitätsproblem")
        XCTAssertEqual(TranscriptPolish.flattenLineBreaks("was zu dikt\nieren, was"),
                       "was zu diktieren, was")
    }

    func testFlattenReplacesLineBreaksBetweenWordsWithSpace() {
        // Umbrüche ZWISCHEN Wörtern tragen im Korpus immer ein Leerzeichen —
        // sie (und Mehrfach-Leerraum) werden zu genau einem Leerzeichen.
        XCTAssertEqual(TranscriptPolish.flattenLineBreaks("ausgeschaltet,\n weil ich"),
                       "ausgeschaltet, weil ich")
        XCTAssertEqual(TranscriptPolish.flattenLineBreaks("Hallo\nWelt  und   mehr"),
                       "Hallo Welt und mehr")
    }

    // MARK: Deterministische Nachstufe — Satzzeichen-/Großschreibungs-Reparatur

    func testRepairTurnsMidSentencePeriodIntoComma() {
        XCTAssertEqual(
            TranscriptPolish.repairPunctuation("Die Bereinigung ist ausgefallen. und zwar öfter"),
            "Die Bereinigung ist ausgefallen, und zwar öfter")
    }

    func testRepairKeepsAbbreviationsNumbersAndEllipses() {
        // "B." ist kürzer als 3 Buchstaben -> Abkürzung, bleibt unangetastet.
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Wir nehmen z. B. und zwar gerne Äpfel"),
                       "Wir nehmen z. B. und zwar gerne Äpfel")
        // Zahlen/Datumsangaben bleiben unangetastet.
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Das Abo geht bis zum 27.07. und endet dann"),
                       "Das Abo geht bis zum 27.07. und endet dann")
        // Auslassungspunkte sind kein Satzende und kein Artefakt.
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Moment... dann eben nicht"),
                       "Moment... dann eben nicht")
    }

    func testRepairKeepsGermanAbbreviationsLongerThanTwoLetters() {
        // Die Längenregel (Wort vor dem Punkt kürzer als 3 Buchstaben) schützt nur
        // "z. B."-artige Kürzel. Gängige längere Abkürzungen stehen deshalb auf
        // einer eigenen Schutzliste — sonst wird aus "ggf." ein "ggf,".
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Das gilt ggf. auch für uns"),
                       "Das gilt ggf. auch für uns")
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Wir liefern Schrauben bzw. dazu passende Muttern"),
                       "Wir liefern Schrauben bzw. dazu passende Muttern")
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Der Preis gilt inkl. aller Kosten usw. und bleibt"),
                       "Der Preis gilt inkl. aller Kosten usw. und bleibt")
        // Ein normales Wort vor dem Punkt bleibt dagegen ein Segment-Artefakt.
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Das war der Bericht. und zwar komplett"),
                       "Das war der Bericht, und zwar komplett")
    }

    func testRepairCollapsesDoubledPunctuation() {
        // Entsteht, wenn ein leer zurückgesetzter Satzteil seine Rand-Interpunktion
        // hinterlässt ("Wort, , dass").
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Das kostet 200 Dollar, , dass wir das nutzen"),
                       "Das kostet 200 Dollar, dass wir das nutzen")
        XCTAssertEqual(TranscriptPolish.repairPunctuation("Genau, , , also gut."),
                       "Genau, also gut.")
    }

    func testRepairCapitalizesAfterRealSentenceEnds() {
        XCTAssertEqual(TranscriptPolish.repairPunctuation("geht das? ja klar! gerne"),
                       "Geht das? Ja klar! Gerne")
    }

    // MARK: Kölner Phonetik

    func testColognePhoneticsMatchesSoundAlikes() {
        XCTAssertEqual(TranscriptPolish.colognePhonetics("Rack"),
                       TranscriptPolish.colognePhonetics("RAG"))
        XCTAssertEqual(TranscriptPolish.colognePhonetics("Meier"),
                       TranscriptPolish.colognePhonetics("Mayr"))
        XCTAssertNotEqual(TranscriptPolish.colognePhonetics("verbinden"),
                          TranscriptPolish.colognePhonetics("verwenden"))
    }

    // MARK: Whisper-Artefakte

    func testArtifactMarkersRemoved() {
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts(" [Musik] Hallo Welt (Räuspern) "), "Hallo Welt")
    }

    func testKnownHallucinationBecomesEmpty() {
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts("Untertitel im Auftrag des ZDF für funk, 2017"), "")
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts("Vielen Dank für's Zuschauen!"), "")
    }

    func testNormalTextUntouched() {
        XCTAssertEqual(WhisperClient.cleanWhisperArtifacts("Ganz normaler Satz."), "Ganz normaler Satz.")
    }

    func testWhisperEndpointAcceptsOnlyExplicitLoopbackAddresses() throws {
        let ipv4 = try WhisperEndpoint(serverURL: "http://127.23.4.5:8181")
        XCTAssertEqual(ipv4.inferenceURL.absoluteString, "http://127.23.4.5:8181/inference")
        XCTAssertEqual(ipv4.port, 8181)

        let ipv6 = try WhisperEndpoint(serverURL: "http://[::1]:9090/")
        XCTAssertEqual(ipv6.port, 9090)

        for unsafe in [
            "http://localhost:8181",
            "http://192.0.2.10:8181",
            "https://127.0.0.1:8181",
            "http://127.0.0.1",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
            "http://127.0.0.1:8181/prefix",
            "http://user@127.0.0.1:8181",
            "http://[::ffff:127.0.0.1]:8181",
        ] {
            XCTAssertThrowsError(try WhisperEndpoint(serverURL: unsafe), unsafe)
        }
    }

    func testWhisperServerLaunchArgumentsBindTheConfiguredHost() throws {
        // Der Autostart muss GENAU die validierte Adresse binden, die auch die
        // Erreichbarkeitsprüfung ansprechen wird — sonst läuft eine gültige
        // Konfiguration wie "http://[::1]:9191" stur in den Start-Timeout.
        let ipv4 = try WhisperEndpoint(serverURL: "http://127.23.4.5:9090")
        XCTAssertEqual(
            WhisperServerManager.launchArguments(model: "m.bin", endpoint: ipv4, threads: 4),
            ["-m", "m.bin", "--host", "127.23.4.5", "--port", "9090", "-t", "4"]
        )
        let ipv6 = try WhisperEndpoint(serverURL: "http://[::1]:9191")
        XCTAssertEqual(
            WhisperServerManager.launchArguments(model: "m.bin", endpoint: ipv6, threads: 2),
            ["-m", "m.bin", "--host", "::1", "--port", "9191", "-t", "2"]
        )
    }

    /// Winziger Loopback-HTTP-Server für Redirect-Tests: antwortet auf jede
    /// vollständige Anfrage mit einer festen Antwort und zählt die Anfragen.
    private final class TinyHTTPServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "de.stillepost.test.tiny-http")
        private let lock = NSLock()
        private var hits = 0
        private let responseText: String

        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return hits }
        var port: Int { Int(listener.port?.rawValue ?? 0) }

        init(response: String) throws {
            responseText = response
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed: ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.read(connection, buffer: Data(), counted: false)
            }
            listener.start(queue: queue)
            _ = ready.wait(timeout: .now() + 5)
        }

        deinit {
            listener.cancel()
        }

        private func read(_ connection: NWConnection, buffer: Data, counted: Bool) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                var buffer = buffer
                var counted = counted
                if let data, !data.isEmpty {
                    buffer += data
                    if !counted {
                        counted = true
                        self.lock.lock(); self.hits += 1; self.lock.unlock()
                    }
                }
                // Erst nach der VOLLSTÄNDIGEN Anfrage antworten (Content-Length
                // abgewartet) — so verhält sich der Testserver wie ein echter.
                switch BridgeHTTP.parse(buffer, maxBodyBytes: 64 * 1_048_576) {
                case .complete:
                    connection.send(content: Data(self.responseText.utf8),
                                    contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                case .incomplete:
                    if isComplete || error != nil {
                        connection.cancel()
                    } else {
                        self.read(connection, buffer: buffer, counted: counted)
                    }
                case .failure:
                    connection.cancel()
                }
            }
        }
    }

    func testWhisperClientRefusesToFollowRedirects() throws {
        // Szenario aus der Datenschutzregel: Der (kompromittierte oder falsch
        // konfigurierte) lokale whisper-server antwortet mit 307. Eine
        // 307-Weiterleitung behält den POST-Body — folgte URLSession ihr, ginge
        // das komplette Audio an den NIE gegen die Loopback-Regel geprüften
        // Host aus dem Location-Kopf.
        let victim = try TinyHTTPServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        )
        XCTAssertGreaterThan(victim.port, 0)
        let redirector = try TinyHTTPServer(
            response: "HTTP/1.1 307 Temporary Redirect\r\n"
                + "Location: http://127.0.0.1:\(victim.port)/inference\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        )
        XCTAssertGreaterThan(redirector.port, 0)

        var whisper = Config.Whisper()
        whisper.serverURL = "http://127.0.0.1:\(redirector.port)"
        let client = WhisperClient(config: whisper)

        let finished = expectation(description: "Transkription beendet")
        Task {
            do {
                _ = try await client.transcribe(samples: [Float](repeating: 0, count: 1600))
                XCTFail("Eine Weiterleitung darf kein Erfolg sein")
            } catch {
                // Erwartet: Die 307-Antwort wird als Serverfehler gemeldet.
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(redirector.requestCount, 1)
        // Kurze Karenz, damit ein fälschlich doch gefolgter Redirect auffiele.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(victim.requestCount, 0, "Audio darf einem Redirect NIE folgen")
    }

    func testWhisperServerManagerStopsOwnedProcessOnDeinit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        var manager: WhisperServerManager? = WhisperServerManager(
            config: Config.Whisper(), ownedProcess: process
        )
        XCTAssertTrue(process.isRunning)

        manager = nil
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            XCTFail("Eigener Kindprozess lief nach Manager-deinit weiter")
        }
        XCTAssertNil(manager)
    }

    // MARK: Denk-Blöcke von Reasoning-Modellen

    func testStripThinking() {
        XCTAssertEqual(CleanupService.stripThinking("<think>Überlegung…</think>Fertiger Text"), "Fertiger Text")
        XCTAssertEqual(CleanupService.stripThinking("Ohne Denkblock"), "Ohne Denkblock")
    }

    // MARK: Segmente zusammenfügen

    func testJoinSegments() {
        XCTAssertEqual(DictationEngine.joinSegments(["Erster Teil.", " Zweiter Teil. ", ""]),
                       "Erster Teil. Zweiter Teil.")
        XCTAssertEqual(DictationEngine.joinSegments([]), "")
    }

    @MainActor
    func testCancelInvalidatesProcessingBeforeItCanPersistOrDeliver() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let cleanupGate = CleanupGate()
        let history = HistoryStore(baseDir: baseDir)
        let engine = DictationEngine(config: Config(), history: history) { rawText in
            await cleanupGate.clean(rawText)
        }
        var deliveredTexts: [String] = []
        engine.onResult = { deliveredTexts.append($0.text) }

        engine.processForTesting(rawText: "nicht mehr ausliefern")
        await cleanupGate.waitUntilStarted()
        engine.cancel()
        await cleanupGate.release()
        await cleanupGate.waitUntilFinished()
        await Task.yield()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertTrue(deliveredTexts.isEmpty)
        XCTAssertTrue(try history.list().isEmpty)
    }

    @MainActor
    func testCancelDuringProcessingRemovesTheRecording() async throws {
        // Beim Stoppen nimmt die Engine dem Writer die fertige WAV-Datei ab.
        // Wurde danach abgebrochen, kannte sie niemand mehr: Der Verlauf bekommt
        // bei einem Abbruch keinen Eintrag, der Writer war schon weg — eine
        // vollstaendige Aufnahme blieb unauffindbar auf der Platte liegen.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-cancel-wav-\(UUID())")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let wavURL = baseDir.appendingPathComponent("aufnahme.wav")
        try Data("RIFF".utf8).write(to: wavURL)

        let cleanupGate = CleanupGate()
        let history = HistoryStore(baseDir: baseDir.appendingPathComponent("verlauf"))
        let engine = DictationEngine(config: Config(), history: history) { rawText in
            await cleanupGate.clean(rawText)
        }

        engine.processForTesting(rawText: "abgebrochen", wavURL: wavURL)
        await cleanupGate.waitUntilStarted()
        engine.cancel()
        await cleanupGate.release()
        await cleanupGate.waitUntilFinished()
        await Task.yield()

        XCTAssertFalse(FileManager.default.fileExists(atPath: wavURL.path),
                       "die Aufnahme der abgebrochenen Verarbeitung muss weg sein")
        XCTAssertTrue(try history.list().isEmpty, "und im Verlauf steht auch nichts")
    }

    @MainActor
    func testUndeletableRecordingStillDeliversTheDictation() async throws {
        // Der Text ist transkribiert, bereinigt und im Verlauf gespeichert; nur
        // das Wegraeumen der Diagnoseaufnahme scheitert (hier: schreibgeschuetzter
        // Ordner). Das ist ein Aufraeumproblem — das fertige Diktat gehoert
        // trotzdem ausgeliefert, sonst faellt es wegen einer Nebensache unter den
        // Tisch. Der Fehler wird zusaetzlich gemeldet.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-undeletable-\(UUID())")
        let history = HistoryStore(baseDir: baseDir.appendingPathComponent("verlauf"))
        let blocked = history.recordingsDir
        let wavURL = history.newRecordingURL()
        try Data("RIFF".utf8).write(to: wavURL)
        // Ohne Schreibrecht am Ordner laesst sich die Datei darin nicht loeschen.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: baseDir)
        }

        let engine = DictationEngine(config: Config(), history: history) { rawText in
            CleanupService.Result(text: rawText, usedFallback: false,
                                  fallbackReason: nil, endpoint: nil)
        }
        let delivered = expectation(description: "onResult ausgeliefert")
        var deliveredText: String?
        var deliveredEntry: HistoryStore.Entry?
        engine.onResult = {
            deliveredText = $0.text
            deliveredEntry = $0.entry
            delivered.fulfill()
        }
        // Der Fehler wird nach der Auslieferung gemeldet — auf beides warten,
        // sonst haengt das Ergebnis von der Reihenfolge zweier Threads ab.
        let reported = expectation(description: "Aufraeumfehler gemeldet")
        var reportedError: String?
        engine.onStateChange = { state in
            if case .error(let message) = state {
                reportedError = message
                reported.fulfill()
            }
        }

        engine.processForTesting(rawText: "das diktat darf nicht verloren gehen",
                                 wavURL: wavURL)
        await fulfillment(of: [delivered, reported], timeout: 5)

        XCTAssertEqual(deliveredText, "das diktat darf nicht verloren gehen")
        XCTAssertNotNil(deliveredEntry, "der Verlaufseintrag gehoert mit ausgeliefert")
        XCTAssertEqual(try history.list().count, 1, "im Verlauf steht der Eintrag")
        XCTAssertEqual(deliveredEntry?.audioFileName, wavURL.lastPathComponent,
                       "der ausgelieferte Eintrag hält den dauerhaften WAV-Verweis")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path),
                      "die Aufnahme bleibt liegen — genau darum geht es")
        XCTAssertNotNil(reportedError, "das gescheiterte Aufraeumen muss gemeldet werden")
    }

    @MainActor
    func testUndeletableSilentRecordingStaysReachableInHistory() async throws {
        // Reine Stille erzeugt normalerweise keinen Verlaufseintrag. Lässt sich
        // ihre WAV aber nicht löschen, darf der einzige Verweis nicht nur im RAM
        // der Engine bleiben: Das nächste Diktat würde ihn überschreiben, und nach
        // einem Neustart fände "Alle löschen" die Aufnahme nie wieder.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-silent-undeletable-\(UUID())")
        let history = HistoryStore(baseDir: baseDir.appendingPathComponent("verlauf"))
        let blocked = history.recordingsDir
        let wavURL = history.newRecordingURL()
        try Data("RIFF".utf8).write(to: wavURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: baseDir)
        }

        let engine = DictationEngine(config: Config(), history: history)
        let delivered = expectation(description: "stilles Ergebnis ausgeliefert")
        var deliveredEntry: HistoryStore.Entry?
        engine.onResult = {
            deliveredEntry = $0.entry
            delivered.fulfill()
        }

        engine.processForTesting(rawText: "", wavURL: wavURL)
        await fulfillment(of: [delivered], timeout: 5)

        XCTAssertNotNil(deliveredEntry, "der Dateiverweis muss den Neustart überleben")
        let stored = try history.list()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.audioFileName, wavURL.lastPathComponent)
        XCTAssertTrue(stored.first?.rawText.isEmpty == true)
        XCTAssertTrue(stored.first?.cleanText.isEmpty == true)
        guard case .error = engine.state else {
            return XCTFail("das gescheiterte Löschen muss sichtbar sein")
        }
    }

    @MainActor
    func testResultIsDeliveredOnMainThread() async throws {
        // Regression 0.8.13: Die Nachverarbeitung lief off-main; onResult fasst aber
        // im App-Callback AppKit an (Overlay-Panel), und AppKit bricht ab macOS 26
        // hart ab, wenn das off-main geschieht. Der Vertrag lautet "onResult auf
        // Main-Thread" — genau das prüft dieser Test, unabhängig davon, wo die
        // Verarbeitung selbst gerade läuft.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-deliver-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let history = HistoryStore(baseDir: baseDir)
        // Bereinigung synchron und ohne Netzwerk halten: getestet wird nur die
        // Thread-Zusage der Auslieferung, nicht die Bereinigung selbst.
        let engine = DictationEngine(config: Config(), history: history) { rawText in
            CleanupService.Result(text: rawText, usedFallback: false,
                                  fallbackReason: nil, endpoint: nil)
        }
        let delivered = expectation(description: "onResult ausgeliefert")
        var deliveredOnMainThread: Bool?
        engine.onResult = { _ in
            deliveredOnMainThread = Thread.isMainThread
            delivered.fulfill()
        }

        engine.processForTesting(rawText: "hallo welt")
        await fulfillment(of: [delivered], timeout: 5)

        XCTAssertEqual(deliveredOnMainThread, true,
                       "onResult MUSS auf dem Main-Thread ausgeliefert werden (Overlay/AppKit)")
    }

    @MainActor
    func testSuccessfulAudioIsPersistedBeforeDeletionAndWritesOffMainThread() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-disk-first-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let firstWrite = LockedTestValue<(HistoryStore.Entry?, Bool?)>((nil, nil))
        let history = HistoryStore(baseDir: baseDir) { data, url in
            firstWrite.update { write in
                if write.0 == nil {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let entry = try? decoder.decode([HistoryStore.Entry].self, from: data).first
                    write = (entry, Thread.isMainThread)
                }
            }
            try data.write(to: url, options: .atomic)
        }
        let wavURL = history.newRecordingURL()
        try Data("RIFF".utf8).write(to: wavURL)
        let engine = DictationEngine(config: Config(), history: history) { rawText in
            CleanupService.Result(text: rawText, usedFallback: false,
                                  fallbackReason: nil, endpoint: nil)
        }
        let delivered = expectation(description: "Diktat fertig")
        engine.onResult = { _ in delivered.fulfill() }

        engine.processForTesting(rawText: "disk first", wavURL: wavURL)
        await fulfillment(of: [delivered], timeout: 5)

        let (first, wasMain) = firstWrite.snapshot
        XCTAssertEqual(first?.audioFileName, wavURL.lastPathComponent,
                       "der erste bestätigte Plattenstand muss die WAV kennen")
        XCTAssertEqual(wasMain, false, "JSON/Lock/Write dürfen den MainActor nicht blockieren")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavURL.path))
        XCTAssertNil(try history.list().first?.audioFileName,
                     "erst nach bestätigtem Löschen verschwindet der Verweis")
    }

    @MainActor
    func testShutdownPreservesRecordingAfterPersistenceFailure() async throws {
        enum Expected: Error { case writeFailure }
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-shutdown-error-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let history = HistoryStore(baseDir: baseDir) { _, _ in throw Expected.writeFailure }
        let wavURL = history.newRecordingURL()
        try Data("RIFF".utf8).write(to: wavURL)
        let engine = DictationEngine(config: Config(), history: history) { rawText in
            CleanupService.Result(text: rawText, usedFallback: false,
                                  fallbackReason: nil, endpoint: nil)
        }
        let failed = expectation(description: "Persistenzfehler sichtbar")
        engine.onStateChange = { state in
            if case .error = state { failed.fulfill() }
        }

        engine.processForTesting(rawText: "Diagnose behalten", wavURL: wavURL)
        await fulfillment(of: [failed], timeout: 5)
        engine.shutdown()

        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path),
                      "shutdown darf die Aufnahme des Fehlerzustands nicht löschen")
        guard case .error = engine.state else {
            return XCTFail("shutdown darf den zugehörigen Fehlerzustand nicht verwischen")
        }
    }

    @MainActor
    func testFinalHistoryWriteFailureStillDeliversCompletedDictation() async throws {
        enum Expected: Error { case secondWriteFailure }
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-final-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let writes = LockedTestValue(0)
        let history = HistoryStore(baseDir: baseDir) { data, url in
            let attempt = writes.update { count in count += 1; return count }
            if attempt == 2 { throw Expected.secondWriteFailure }
            try data.write(to: url, options: .atomic)
        }
        let wavURL = history.newRecordingURL()
        try Data("RIFF".utf8).write(to: wavURL)
        let engine = DictationEngine(config: Config(), history: history) { rawText in
            CleanupService.Result(text: rawText, usedFallback: false,
                                  fallbackReason: nil, endpoint: nil)
        }
        let delivered = expectation(description: "fertiger Text ausgeliefert")
        let reported = expectation(description: "abschließender Write-Fehler gemeldet")
        var deliveredText: String?
        var deliveredEntry: HistoryStore.Entry?
        engine.onResult = {
            deliveredText = $0.text
            deliveredEntry = $0.entry
            delivered.fulfill()
        }
        engine.onStateChange = { state in
            if case .error = state { reported.fulfill() }
        }

        engine.processForTesting(rawText: "fertiges Diktat", wavURL: wavURL)
        await fulfillment(of: [delivered, reported], timeout: 5)

        XCTAssertEqual(deliveredText, "fertiges Diktat")
        XCTAssertEqual(deliveredEntry?.audioFileName, wavURL.lastPathComponent,
                       "das Ergebnis bildet den weiterhin persistierten Stand ab")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavURL.path),
                       "die bereits bestätigt gelöschte WAV bleibt gelöscht")
        XCTAssertEqual(try history.list().first?.audioFileName, wavURL.lastPathComponent,
                       "der erste sichere Stand bleibt beim zweiten Write-Fehler lesbar")
    }

    @MainActor
    func testRetryKeepsAudioReferenceWhenDeletionFails() async throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-retry-disk-first-\(UUID())")
        let history = HistoryStore(baseDir: baseDir)
        let wavURL = history.newRecordingURL()
        try Data("RIFF".utf8).write(to: wavURL)
        let failedEntry = HistoryStore.Entry(
            rawText: "", cleanText: "", status: "failed",
            errorMessage: "alter Fehler", audioFileName: wavURL.lastPathComponent,
            durationSec: 1
        )
        try history.append(failedEntry)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: history.recordingsDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: history.recordingsDir.path)
            try? FileManager.default.removeItem(at: baseDir)
        }

        let transcriber = RetryTranscriber()
        let cleanup = RetryCleanup()
        let dependencies = DictationDependencies(
            transcriber: transcriber,
            server: RetryServer(),
            cleanup: cleanup,
            makeRecorder: { _ in fatalError("im Retry unbenutzt") },
            makeSegmenter: { _ in fatalError("im Retry unbenutzt") },
            makeWavWriter: { _ in fatalError("im Retry unbenutzt") }
        )
        let engine = DictationEngine(config: Config(), history: history,
                                     dependencies: dependencies)

        do {
            _ = try await engine.retry(entry: failedEntry)
            XCTFail("das gescheiterte Löschen muss gemeldet werden")
        } catch {}

        let retained = try XCTUnwrap(history.list().first)
        XCTAssertEqual(retained.status, "ok", "die Transkription war erfolgreich")
        XCTAssertEqual(retained.audioFileName, wavURL.lastPathComponent,
                       "der WAV-Verweis darf vor bestätigtem Löschen nicht verschwinden")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path))
    }

    // MARK: Config

    func testConfigToleratesMissingFields() throws {
        // Eine alte/minimale Config-Datei darf nicht crashen — fehlende Felder = Defaults.
        let json = #"{"cleanup": {"model": "anderes-modell"}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.cleanup.model, "anderes-modell")
        XCTAssertEqual(config.cleanup.provider, "ollama", "fehlendes Feld muss Default bekommen")
        XCTAssertEqual(config.whisper.threads, 4, "fehlende Sektion muss komplette Defaults bekommen")
        XCTAssertEqual(config.audio.inputDeviceUID, "", "alte Configs müssen beim Systemstandard bleiben")
    }

    func testConfigRoundTrip() throws {
        var config = Config()
        config.cleanup.provider = "openai"
        config.cleanup.remote.baseURL = "https://api.example.com/v1"
        config.audio.inputDeviceUID = "test-device-uid"
        config.audio.inputDeviceName = "Test-Mikrofon"
        let data = try JSONEncoder().encode(config)
        let restored = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(restored, config)
    }

    func testWrongConfigFieldTypeOnlyDefaultsThatField() throws {
        let json = #"{"cleanup":{"enabled":false,"model":"eigenes-modell","numCtx":"falsch"}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertFalse(config.cleanup.enabled, "gültiges Datenschutz-Feld muss erhalten bleiben")
        XCTAssertEqual(config.cleanup.model, "eigenes-modell")
        XCTAssertEqual(config.cleanup.numCtx, Config.Cleanup().numCtx)
    }

    func testDecodedVadDefaultsOnlyInvalidSemanticValues() throws {
        let json = #"{"vad":{"silenceThresholdDb":-35,"minSegmentSec":2,"maxSegmentSec":12,"paddingSec":-1}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

        XCTAssertEqual(config.vad.silenceThresholdDb, -35)
        XCTAssertEqual(config.vad.minSegmentSec, 2)
        XCTAssertEqual(config.vad.maxSegmentSec, 12)
        XCTAssertEqual(config.vad.paddingSec, Config.Vad().paddingSec)
        XCTAssertNoThrow(try config.validate())
    }

    func testConfigValidationRejectsInconsistentVadBeforeSave() {
        var config = Config()
        config.vad.minSegmentSec = 5
        config.vad.maxSegmentSec = 1
        XCTAssertThrowsError(try config.validate())
    }

    func testAudioDeviceCatalogContainsTheSystemDefaultWhenAvailable() throws {
        // Hardware-Integration ohne Aufnahme: Auf einem Rechner ohne Mikrofon wird
        // sauber übersprungen; sonst muss der macOS-Default auch in der Liste stehen.
        guard let defaultDevice = AudioInputDeviceCatalog.defaultDevice() else {
            throw XCTSkip("Kein Standard-Eingabegerät auf diesem Testrechner")
        }
        XCTAssertTrue(AudioInputDeviceCatalog.availableDevices().contains(defaultDevice))
    }

    func testSystemDefaultCanBeSelectedExplicitlyOnAudioEngine() throws {
        guard let defaultDevice = AudioInputDeviceCatalog.defaultDevice() else {
            throw XCTSkip("Kein Standard-Eingabegerät auf diesem Testrechner")
        }
        // Der Engine-Start würde eine echte Aufnahme und TCC-Berechtigung brauchen.
        // Das Setzen am echten AVAudioInputNode prüft bereits die CoreAudio-Brücke.
        let engine = AVAudioEngine()
        XCTAssertNoThrow(try AudioInputDeviceCatalog.apply(
            uid: defaultDevice.uid,
            to: engine.inputNode
        ))
    }

    // MARK: Bereinigungs-Kette (primär + Fallbacks)

    func testCleanupChainWithoutFallbacksIsJustPrimary() throws {
        // Eine Config ohne fallbacks-Feld (alle Bestands-Configs!) muss sich exakt
        // wie bisher verhalten: Kette = nur der primäre Endpoint.
        let json = #"{"cleanup": {"ollamaURL": "http://127.0.0.1:11434", "model": "test-modell"}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain.count, 1)
        XCTAssertEqual(chain[0].model, "test-modell")
        XCTAssertEqual(chain[0].provider, "ollama")
    }

    // MARK: Hotkey

    func testHotkeyNeedsAStrongModifier() {
        // Sicherheitsgrenze des Hotkey-Recorders: Ein global registrierter Hotkey
        // OHNE ⌘/⌥/⌃ würde die Taste systemweit schlucken — dann ließe sich das
        // Zeichen nirgends mehr tippen.
        var hotkey = Config.Hotkey()
        hotkey.modifiers = []
        XCTAssertFalse(hotkey.isUsableGlobally, "nackte Taste darf nicht durchgehen")
        hotkey.modifiers = ["shift"]
        XCTAssertFalse(hotkey.isUsableGlobally, "⇧ allein reicht nicht — ⇧D ist ein Großbuchstabe")
        hotkey.modifiers = ["cmd"]
        XCTAssertTrue(hotkey.isUsableGlobally)
        hotkey.modifiers = ["shift", "ctrl"]
        XCTAssertTrue(hotkey.isUsableGlobally, "⇧ zusammen mit ⌃ ist in Ordnung")
    }

    func testHotkeyDefaultIsUsable() {
        // Der eingebaute Default ⌘⌥D muss die eigene Regel erfüllen.
        XCTAssertTrue(Config.Hotkey().isUsableGlobally)
    }

    // MARK: Verlauf

    func testHistoryStoreAppendAndDeleteAll() throws {
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-test-\(UUID())")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let store = HistoryStore(baseDir: baseDir)
        // Fehlgeschlagenen Eintrag mit Audio-Datei anlegen.
        let audioURL = store.newRecordingURL()
        try Data("wav".utf8).write(to: audioURL)
        try store.append(HistoryStore.Entry(rawText: "", cleanText: "", status: "failed",
                                        errorMessage: "Test", audioFileName: audioURL.lastPathComponent,
                                        durationSec: 3))
        try store.append(HistoryStore.Entry(rawText: "roh", cleanText: "sauber", status: "ok", durationSec: 5,
                                        cleanupEndpoint: "modell @ http://127.0.0.1:11434", cleanupSec: 1.2))

        XCTAssertEqual(try store.list().count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        // Neu laden (Persistenz prüfen) — inkl. der Diagnose-Felder der Bereinigung.
        let reloaded = HistoryStore(baseDir: baseDir)
        XCTAssertEqual(try reloaded.list().count, 2)
        let okEntry = try reloaded.list().first { $0.status == "ok" }
        XCTAssertEqual(okEntry?.cleanupEndpoint, "modell @ http://127.0.0.1:11434")
        XCTAssertEqual(okEntry?.cleanupSec, 1.2)

        // Alle löschen muss auch die Audio-Datei entfernen.
        try reloaded.deleteAll()
        XCTAssertEqual(try reloaded.list().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testAudioNameThatLeavesTheRecordingsFolderIsRefusedOnBothPaths() throws {
        // `audioFileName` steht in history.json. Beim Löschen war ein Ausbruch aus
        // dem Aufnahme-Ordner längst abgefangen, beim Lesen nicht — dabei ist
        // gerade der Lesepfad der gefährlichere: „Erneut transkribieren“ hätte
        // eine beliebige Datei des Rechners an den whisper-server geschickt.
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-name-\(UUID())")
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = HistoryStore(baseDir: baseDir)

        for unsafe in ["../heimlich.wav", "unter/ordner.wav", "/etc/passwd", ""] {
            let entry = HistoryStore.Entry(rawText: "", cleanText: "", status: "failed",
                                           audioFileName: unsafe, durationSec: 1)
            XCTAssertNil(store.audioURL(for: entry),
                         "„\(unsafe)“ darf keinen Lesepfad ergeben")
            XCTAssertThrowsError(try store.deleteAudio(for: entry),
                                 "„\(unsafe)“ darf auch nicht gelöscht werden")
        }

        // Gegenprobe: Ein normaler Name aus `newRecordingURL` bleibt benutzbar.
        let regular = HistoryStore.Entry(
            rawText: "", cleanText: "", status: "failed",
            audioFileName: store.newRecordingURL().lastPathComponent, durationSec: 1
        )
        XCTAssertNotNil(store.audioURL(for: regular))
        XCTAssertNoThrow(try store.deleteAudio(for: regular))
    }

    func testDeleteAllRemovesEveryRecordingEvenIfOneNameIsRefused() throws {
        // "Alle loeschen" ist der Datenschutz-Knopf: Danach darf keine Aufnahme
        // mehr liegen. Bisher brach die Schleife beim ersten unsicheren Namen ab —
        // der Verlauf war da schon leer, und alle danach kommenden Aufnahmen
        // blieben ohne Eintrag auf der Platte zurueck, also unauffindbar.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-deleteall-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = HistoryStore(baseDir: baseDir)
        let audioURL = store.newRecordingURL()
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: audioURL)

        // Der unsichere Name steht ZUERST — genau dort brach die Schleife ab.
        try store.append(.init(rawText: "", cleanText: "", status: "failed",
                               audioFileName: "../heimlich.wav", durationSec: 1))
        try store.append(.init(rawText: "", cleanText: "", status: "failed",
                               audioFileName: audioURL.lastPathComponent, durationSec: 1))

        XCTAssertThrowsError(try store.deleteAll(), "der unsichere Name muss gemeldet werden")

        XCTAssertEqual(try store.list().count, 0, "der Verlauf ist leer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path),
                       "die zweite Aufnahme muss trotzdem weg sein")
    }

    func testDeleteAllKeepsAReferenceToAnUndeletableRecording() throws {
        // "Alle loeschen" schreibt zuerst den leeren Verlauf und loescht danach die
        // Aufnahmen. Scheitert das Loeschen einer legitimen Aufnahme (Rechte,
        // gesperrte Datei), kannte danach niemand mehr ihren Namen — ein zweiter
        // Klick fand sie nicht, und die Datei blieb fuer immer liegen.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-deleteall-blocked-\(UUID())")
        let store = HistoryStore(baseDir: baseDir)
        let audioURL = store.newRecordingURL()
        try Data("wav".utf8).write(to: audioURL)
        try store.append(.init(rawText: "geheim", cleanText: "geheim", status: "failed",
                               audioFileName: audioURL.lastPathComponent, durationSec: 3))

        // Ohne Schreibrecht am Aufnahme-Ordner laesst sich die Datei nicht loeschen.
        let recordings = store.recordingsDir
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: recordings.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: recordings.path)
            try? FileManager.default.removeItem(at: baseDir)
        }

        XCTAssertThrowsError(try store.deleteAll(), "das gescheiterte Loeschen muss gemeldet werden")

        let remaining = try store.list()
        XCTAssertEqual(remaining.count, 1, "der Verweis auf die Aufnahme bleibt")
        XCTAssertEqual(remaining.first?.audioFileName, audioURL.lastPathComponent)
        XCTAssertEqual(remaining.first?.cleanText, "", "der Text ist trotzdem geloescht")
        XCTAssertEqual(remaining.first?.rawText, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testHistoryStoresReloadInsideCrossProcessLock() throws {
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-lock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let appStore = HistoryStore(baseDir: baseDir)
        let cliStore = HistoryStore(baseDir: baseDir)

        try appStore.append(.init(rawText: "alt", cleanText: "alt", status: "ok", durationSec: 1))
        try cliStore.deleteAll()
        try appStore.append(.init(rawText: "neu", cleanText: "neu", status: "ok", durationSec: 1))

        XCTAssertEqual(try HistoryStore(baseDir: baseDir).list().map(\.cleanText), ["neu"])
    }

    func testHistoryWriteFailureKeepsDiskStateAndAudio() throws {
        enum Expected: Error { case writeFailure }
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("sp-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let working = HistoryStore(baseDir: baseDir)
        let audioURL = working.newRecordingURL()
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: audioURL)
        try working.append(.init(rawText: "", cleanText: "", status: "failed",
                                 audioFileName: audioURL.lastPathComponent, durationSec: 1))

        let failing = HistoryStore(baseDir: baseDir) { _, _ in throw Expected.writeFailure }
        XCTAssertThrowsError(try failing.deleteAll())
        XCTAssertEqual(try working.list().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDeleteAllSecondWriteFailureKeepsThePredeclaredAudioRemnant() throws {
        enum Expected: Error { case secondWriteFailure }
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-deleteall-second-write-\(UUID())")
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let working = HistoryStore(baseDir: baseDir)
        let audioURL = working.newRecordingURL()
        try Data("wav".utf8).write(to: audioURL)
        try working.append(.init(rawText: "geheim", cleanText: "geheim", status: "failed",
                                 audioFileName: audioURL.lastPathComponent, durationSec: 1))

        let writes = LockedTestValue(0)
        let failing = HistoryStore(baseDir: baseDir) { data, url in
            let attempt = writes.update { count in count += 1; return count }
            if attempt == 2 { throw Expected.secondWriteFailure }
            try data.write(to: url, options: .atomic)
        }
        XCTAssertThrowsError(try failing.deleteAll())

        let persisted = try working.list()
        XCTAssertEqual(persisted.count, 1,
                       "der erste Write muss den Namen auch bei zweitem Write-Fehler bewahren")
        XCTAssertEqual(persisted.first?.audioFileName, audioURL.lastPathComponent)
        XCTAssertEqual(persisted.first?.rawText, "", "der angeforderte Text ist trotzdem gelöscht")
        XCTAssertEqual(persisted.first?.cleanText, "")
    }
}

private final class RetryTranscriber: DictationTranscriber {
    func transcribe(samples: [Float]) async throws -> String { "erneut erkannt" }
    func transcribe(wavFile: URL) async throws -> String { "erneut erkannt" }
    func isReachable() async -> Bool { true }
}

private final class RetryServer: DictationServer {
    func ensureRunning(reachability: any DictationTranscriber) async throws {}
    func stop() {}
}

private final class RetryCleanup: DictationCleanup, @unchecked Sendable {
    var onFallbackEndpoint: (@Sendable (String) -> Void)?
    var onPrimaryRetry: (@Sendable () -> Void)?
    func clean(_ rawText: String) async -> CleanupService.Result {
        CleanupService.Result(text: rawText, usedFallback: false,
                              fallbackReason: nil, endpoint: "test")
    }
    func warmUp() {}
}

/// Steuerbare asynchrone Bereinigung für den Lifecycle-Test. Der Actor vermeidet
/// Timingschätzungen und gibt den wartenden Engine-Task erst nach `cancel()` frei.
private actor CleanupGate {
    private var started = false
    private var released = false
    private var finished = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []

    func clean(_ rawText: String) async -> CleanupService.Result {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        finished = true
        finishedWaiters.forEach { $0.resume() }
        finishedWaiters.removeAll()
        return CleanupService.Result(
            text: rawText, usedFallback: false, fallbackReason: nil, endpoint: nil
        )
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }
}
