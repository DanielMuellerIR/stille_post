import XCTest
import AVFoundation
@testable import StillePostCore

/// Tests für WAV-Verarbeitung, Plausibilitätsprüfung, Artefakt-Filter,
/// Segment-Zusammenfügen und Config-Toleranz.
final class CoreTests: XCTestCase {

    // MARK: WAV

    func testWavRoundTrip() throws {
        // Samples -> WAV-Daten -> Datei -> wieder einlesen: Werte müssen (bis auf
        // 16-Bit-Quantisierung) erhalten bleiben.
        let original: [Float] = (0..<1600).map { 0.8 * sin(Float($0) * 0.05) }
        let data = WavCodec.wavData(from: original)
        XCTAssertEqual(data.count, 44 + original.count * 2, "Header 44 Bytes + 2 Bytes pro Sample")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID()).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let restored = try WavCodec.samples(fromWavFile: url)
        XCTAssertEqual(restored.count, original.count)
        for (a, b) in zip(original, restored) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
    }

    func testWavFileWriterProducesReadableFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url)
        try writer.append([Float](repeating: 0.5, count: 800))
        try writer.append([Float](repeating: -0.5, count: 800))
        try writer.finish()

        let restored = try WavCodec.samples(fromWavFile: url)
        XCTAssertEqual(restored.count, 1600)
        XCTAssertEqual(restored[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(restored[1599], -0.5, accuracy: 0.001)
    }

    // MARK: Plausibilitätsprüfung der Bereinigung

    func testSanityCheckAcceptsNormalCleanup() {
        let raw = "also ähm ich wollte halt mal kurz sagen dass das mit dem diktieren noch nicht so richtig schnell läuft"
        let cleaned = "Ich wollte mal kurz sagen, dass das mit dem Diktieren noch nicht so richtig schnell läuft."
        XCTAssertNil(CleanupService.sanityCheckFailure(raw: raw, cleaned: cleaned))
    }

    func testSanityCheckRejectsMassiveShortening() {
        // Simuliert den realen Fehlerfall: Modell kürzt langes Diktat auf einen Satz.
        let raw = String(repeating: "das ist ein längerer diktierter satz mit vielen wörtern ", count: 10)
        let cleaned = "Okay."
        XCTAssertNotNil(CleanupService.sanityCheckFailure(raw: raw, cleaned: cleaned))
    }

    func testSanityCheckRejectsAnswering() {
        // Simuliert: Modell "beantwortet" das Diktat statt zu putzen (Ausgabe wächst stark).
        let raw = "welche lokalen modelle empfiehlst du für textbereinigung"
        let cleaned = String(repeating: "Hier ist eine Tabelle empfohlener Modelle … ", count: 20)
        XCTAssertNotNil(CleanupService.sanityCheckFailure(raw: raw, cleaned: cleaned))
    }

    func testSanityCheckAllowsShortInputs() {
        // Kurze Diktate dürfen stark schrumpfen ("ähm ja Punkt" -> "Ja.").
        XCTAssertNil(CleanupService.sanityCheckFailure(raw: "ähm ja punkt", cleaned: "Ja."))
    }

    func testSanityCheckRejectsWordReplacement() {
        // Gleiche Länge reichte der alten Prüfung: Eine vermeintliche
        // Rechtschreibkorrektur darf den Inhalt trotzdem nicht verändern.
        XCTAssertNotNil(CleanupService.sanityCheckFailure(
            raw: "Bitte verbinden wir die beiden Geräte morgen",
            cleaned: "Bitte verwenden wir die beiden Geräte morgen."
        ))
    }

    func testSanityCheckRejectsWordReordering() {
        // Auch wenn exakt dieselben Wörter vorkommen, bleibt ihre Reihenfolge Teil
        // des Diktats und darf nicht vom Bereinigungsmodell geglättet werden.
        XCTAssertNotNil(CleanupService.sanityCheckFailure(
            raw: "Heute möchte ich den langen Bericht in Ruhe fertig schreiben",
            cleaned: "Den langen Bericht möchte ich heute in Ruhe fertig schreiben."
        ))
    }

    func testSanityCheckAllowsOrderedWordDeletion() {
        XCTAssertNil(CleanupService.sanityCheckFailure(
            raw: "Also ich ich wollte ähm heute den Bericht schreiben",
            cleaned: "Ich wollte heute den Bericht schreiben."
        ))
    }

    func testSanityCheckRejectsEmpty() {
        XCTAssertNotNil(CleanupService.sanityCheckFailure(raw: "hallo welt", cleaned: ""))
    }

    func testSanityCheckRejectsMarkdownStructures() {
        // Realer Fehlerfall (bei einem anderen Diktat-Tool beobachtet): Das Modell
        // "beantwortet" das Diktat und erzeugt Codeblöcke/Beispiel-Befehle.
        let raw = "bitte noch ein startgeräusch ergänzen das kannst du mit dem generierungstool machen"
        let answered = "Bitte noch ein Startgeräusch ergänzen.\n```\ntool generate --name blup\n```"
        XCTAssertNotNil(CleanupService.sanityCheckFailure(raw: raw, cleaned: answered))
        // Aber: Diktiert jemand selbst über Markdown, dürfen vorhandene Marker bleiben.
        XCTAssertNil(CleanupService.sanityCheckFailure(
            raw: "der code steht in einem ```-Block ähm im readme",
            cleaned: "Der Code steht in einem ```-Block im README."))
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
            "http://192.168.1.10:8181",
            "https://127.0.0.1:8181",
            "http://127.0.0.1",
            "http://127.0.0.1:8181/prefix",
            "http://user@127.0.0.1:8181",
            "http://[::ffff:127.0.0.1]:8181",
        ] {
            XCTAssertThrowsError(try WhisperEndpoint(serverURL: unsafe), unsafe)
        }
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

    // MARK: keep_alive (wie lange das Modell geladen bleibt)

    func testKeepAliveNumericValuesBecomeNumbers() {
        // "-1" und "0" muss Ollama als ZAHL sehen — als String versteht es sie nicht.
        XCTAssertEqual(CleanupService.keepAliveValue("-1") as? Int, -1)
        XCTAssertEqual(CleanupService.keepAliveValue("0") as? Int, 0)
        XCTAssertEqual(CleanupService.keepAliveValue("7200") as? Int, 7200, "Sekunden bleiben Sekunden")
    }

    func testKeepAliveDurationsStayStrings() {
        XCTAssertEqual(CleanupService.keepAliveValue("2h") as? String, "2h")
        XCTAssertEqual(CleanupService.keepAliveValue("30m") as? String, "30m")
        XCTAssertEqual(CleanupService.keepAliveValue(" 20M ") as? String, "20m", "Leerzeichen/Großschreibung tolerieren")
    }

    func testKeepAliveGarbageFallsBackToFiniteValue() {
        // Ein Tippfehler in einer handgeschriebenen config.json darf weder den
        // Request zerschießen noch dauerhaft RAM belegen.
        XCTAssertEqual(CleanupService.keepAliveValue("für immer") as? String, "30m")
        XCTAssertEqual(CleanupService.keepAliveValue("") as? String, "30m")
    }

    func testPinsForeverOnlyForNegativeValues() {
        // Daran hängt der Minuten-Timer der App: Er darf NUR im Dauer-Modus laufen.
        XCTAssertTrue(CleanupService.pinsForever("-1"))
        XCTAssertFalse(CleanupService.pinsForever("2h"))
        XCTAssertFalse(CleanupService.pinsForever("0"), "sofort entladen ist nicht dauerhaft")
        XCTAssertFalse(CleanupService.pinsForever("unsinn"))
    }

    func testKeepAliveDefaultsAreTwoHoursPrimaryAndThirtyMinutesFallback() throws {
        // Bestands-Configs kennen das Feld nicht — sie müssen die neuen Defaults
        // bekommen und dürfen nicht auf einem leeren Wert landen.
        let json = #"{"cleanup": {"model": "test-modell", "fallbacks": [{"provider": "ollama"}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain[0].keepAlive, "2h", "primär: befristet, aber lang genug für eine Sitzung")
        XCTAssertEqual(chain[1].keepAlive, "30m", "Fallback belegt auf knappen Macs nur kurz RAM")
    }

    func testConfiguredKeepAliveReachesTheChain() throws {
        // Der im Dialog gewählte Wert muss beim primären Endpoint ankommen —
        // sonst schickt die App weiter den alten fest verdrahteten Wert.
        let json = #"{"cleanup": {"keepAlive": "-1", "fallbacks": [{"keepAlive": "5m"}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain[0].keepAlive, "-1")
        XCTAssertEqual(chain[1].keepAlive, "5m")
        XCTAssertTrue(CleanupService.pinsForever(chain[0].keepAlive))
    }

    func testCleanupChainOrderAndDefaults() throws {
        // Kette: entfernter Ollama-Rechner -> lokales Ollama -> Cloud-Anbieter.
        // Fehlende Felder in einem Fallback-Eintrag müssen Defaults bekommen.
        let json = """
        {"cleanup": {
            "ollamaURL": "http://192.168.1.50:11434",
            "fallbacks": [
                {"provider": "ollama"},
                {"provider": "openai", "remote": {"baseURL": "https://api.example.com/v1", "model": "cloud-modell"}}
            ]
        }}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let chain = config.cleanup.chain
        XCTAssertEqual(chain.count, 3)
        XCTAssertEqual(chain[0].ollamaURL, "http://192.168.1.50:11434")
        XCTAssertEqual(chain[1].ollamaURL, "http://127.0.0.1:11434", "fehlende Felder im Fallback = Defaults")
        XCTAssertEqual(chain[1].model, "qwen3.5:9b")
        XCTAssertEqual(chain[2].provider, "openai")
        XCTAssertEqual(chain[2].label, "cloud-modell @ https://api.example.com/v1")
    }

    func testPrimaryDirectRequestRetriesOnFreshConnection() throws {
        // Kürzlich erreichbarer Primär-Endpoint: clean() schickt die Anfrage DIREKT
        // (keine Probe); scheitert sie, folgt sofort ein zweiter Versuch über eine
        // frische Verbindung (onPrimaryRetry wird gemeldet). Hier ist der Endpoint
        // tot (geschlossener Port) -> beide Versuche scheitern schnell, Ergebnis
        // ist der Rohtext.
        var cleanup = Config.Cleanup()
        cleanup.ollamaURL = "http://127.0.0.1:1"
        let service = CleanupService(config: cleanup)
        service.notePrimarySuccess()
        var retryReported = false
        service.onPrimaryRetry = { retryReported = true }

        let expectation = expectation(description: "clean")
        var result: CleanupService.Result?
        Task {
            result = await service.clean("roher text der bereinigt werden soll")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        XCTAssertTrue(retryReported, "Zweitversuch muss gemeldet werden (Overlay-Transparenz)")
        XCTAssertEqual(result?.usedFallback, true)
    }

    func testNoDirectRequestWithoutRecentPrimaryContact() throws {
        // OHNE kürzlichen Kontakt (App unterwegs gestartet) gilt der Probe-Pfad:
        // toter Primär-Endpoint => schnell weiter in der Kette, KEIN Zweitversuch.
        var cleanup = Config.Cleanup()
        cleanup.ollamaURL = "http://127.0.0.1:1"
        let service = CleanupService(config: cleanup)
        var retryReported = false
        service.onPrimaryRetry = { retryReported = true }

        let started = Date()
        let expectation = expectation(description: "clean")
        Task {
            _ = await service.clean("roher text")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Probe-Pfad muss schnell aufgeben")
        XCTAssertFalse(retryReported, "ohne Recency-Marker kein Direkt-Zweitversuch")
    }

    func testStreamChunkParsing() {
        // Normales Häppchen
        var parsed = CleanupService.streamChunk(fromLine: #"{"message":{"content":"Hallo "},"done":false}"#)
        XCTAssertEqual(parsed.chunk, "Hallo ")
        XCTAssertFalse(parsed.done)
        // Letzte Zeile: done + oft leerer content
        parsed = CleanupService.streamChunk(fromLine: #"{"message":{"content":""},"done":true}"#)
        XCTAssertTrue(parsed.done)
        // Kaputte/fremde Zeilen still überspringen
        parsed = CleanupService.streamChunk(fromLine: "kein json")
        XCTAssertNil(parsed.chunk)
        XCTAssertFalse(parsed.done)
    }

    func testStreamingCleanAgainstLocalOllamaIfAvailable() throws {
        // Integrationstest des Streaming-Pfads gegen ein ECHTES lokales Ollama —
        // wird übersprungen, wenn keins läuft oder das Default-Modell fehlt
        // (Entwickler-Maschinen-Test, kein harter Bestandteil der Suite).
        let cleanup = Config.Cleanup()
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        guard let data = try? Data(contentsOf: URL(string: "\(cleanup.ollamaURL)/api/tags")!),
              let tags = try? JSONDecoder().decode(Tags.self, from: data),
              tags.models.contains(where: { $0.name == cleanup.model || $0.name.hasPrefix(cleanup.model + ":") }) else {
            throw XCTSkip("Kein lokales Ollama mit \(cleanup.model) — Streaming-Integrationstest übersprungen")
        }
        let service = CleanupService(config: cleanup)
        service.notePrimarySuccess()  // erzwingt den Streaming-Direktpfad
        let expectation = expectation(description: "clean")
        var result: CleanupService.Result?
        Task {
            result = await service.clean("also ähm das ist ist ein streaming test")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 60)
        XCTAssertEqual(result?.usedFallback, false, "Streaming-Bereinigung muss durchlaufen: \(result?.fallbackReason ?? "")")
        XCTAssertFalse(result?.text.isEmpty ?? true)
    }

    func testCleanFallsBackToRawWhenAllEndpointsDead() throws {
        // Zwei bewusst tote Endpoints (geschlossene lokale Ports): clean() darf
        // nicht hängen oder werfen, sondern muss den Rohtext zurückgeben und
        // beide Ausfälle im Fallback-Grund benennen.
        var cleanup = Config.Cleanup()
        cleanup.ollamaURL = "http://127.0.0.1:1"
        var fallback = Config.Cleanup.Endpoint()
        fallback.ollamaURL = "http://127.0.0.1:2"
        cleanup.fallbacks = [fallback]

        let raw = "das ist der rohe text"
        let expectation = expectation(description: "clean")
        var result: CleanupService.Result?
        Task {
            result = await CleanupService(config: cleanup).clean(raw)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        XCTAssertEqual(result?.text, raw)
        XCTAssertEqual(result?.usedFallback, true)
        XCTAssertNil(result?.endpoint)
        XCTAssertTrue(result?.fallbackReason?.contains("127.0.0.1:1") ?? false)
        XCTAssertTrue(result?.fallbackReason?.contains("127.0.0.1:2") ?? false)
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
}
