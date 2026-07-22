import XCTest
import AVFoundation
import AppKit
@testable import StillePostCore

/// Tests für WAV-Verarbeitung, Plausibilitätsprüfung, Artefakt-Filter,
/// Segment-Zusammenfügen und Config-Toleranz.
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

    // MARK: WAV

    func testWavEncodingProducesExpectedHeaderAndSamples() throws {
        let original: [Float] = (0..<1600).map { 0.8 * sin(Float($0) * 0.05) }
        let data = WavCodec.wavData(from: original)
        XCTAssertEqual(data.count, 44 + original.count * 2, "Header 44 Bytes + 2 Bytes pro Sample")
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(wavUInt32(data, at: 40), UInt32(original.count * 2))
        let restored = wavSamples(data)
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

        let restored = wavSamples(try Data(contentsOf: url))
        XCTAssertEqual(restored.count, 1600)
        XCTAssertEqual(restored[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(restored[1599], -0.5, accuracy: 0.001)
    }

    func testWavFileWriterRetainsAndReportsFirstAppendFailure() throws {
        enum Expected: Error { case diskFull }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-fail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WavFileWriter(url: url) { writeIndex in
            if writeIndex == 1 { throw Expected.diskFull }
        }

        XCTAssertThrowsError(try writer.append([0.5]))
        XCTAssertThrowsError(try writer.append([0.25]))
        XCTAssertThrowsError(try writer.finish())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
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

    func testStreamChunkParsing() throws {
        // Normales Häppchen
        var parsed = try CleanupService.streamChunk(fromLine: #"{"message":{"content":"Hallo "},"done":false}"#)
        XCTAssertEqual(parsed.chunk, "Hallo ")
        XCTAssertFalse(parsed.done)
        // Letzte Zeile: done + oft leerer content
        parsed = try CleanupService.streamChunk(fromLine: #"{"message":{"content":""},"done":true}"#)
        XCTAssertTrue(parsed.done)
        XCTAssertThrowsError(try CleanupService.streamChunk(fromLine: "kein json"))
        XCTAssertThrowsError(try CleanupService.streamChunk(fromLine: #"{"error":"Modell abgestürzt"}"#)) {
            guard case CleanupService.CleanupError.providerError(let detail) = $0 else {
                return XCTFail("Falscher Fehler: \($0)")
            }
            XCTAssertEqual(detail, "Modell abgestürzt")
        }
    }

    func testCleanupStreamRequiresExplicitCompletion() async {
        let raw = "das ist ein ausreichend langer roher text der niemals als halbe antwort verloren gehen darf"
        let partial = "Das ist ein ausreichend langer roher Text, der niemals als halbe Antwort"
        let transport = StubCleanupTransport(streams: [
            [#"{"message":{"content":"\#(partial)"},"done":false}"#],
            [#"{"message":{"content":"\#(partial)"},"done":false}"#],
        ])
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        service.notePrimarySuccess()

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, raw)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(transport.streamCallCount, 2, "Direktpfad plus frische Verbindung")
        XCTAssertTrue(result.fallbackReason?.contains("ohne Abschluss") ?? false)
    }

    func testCleanupStreamRetriesProviderErrorOnFreshConnection() async {
        let raw = "also das ist ein vollständiger test für einen provider fehler"
        let cleaned = "Das ist ein vollständiger Test für einen Provider-Fehler."
        let transport = StubCleanupTransport(streams: [
            [#"{"error":"Modell wird neu geladen"}"#],
            [
                #"{"message":{"content":"\#(cleaned)"},"done":false}"#,
                #"{"message":{"content":""},"done":true}"#,
            ],
        ])
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        service.notePrimarySuccess()
        var retryReported = false
        service.onPrimaryRetry = { retryReported = true }

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, cleaned)
        XCTAssertFalse(result.usedFallback)
        XCTAssertTrue(retryReported)
        XCTAssertEqual(transport.streamCallCount, 2)
    }

    func testCleanupFallsBackAfterTwoIncompletePrimaryStreams() async {
        let raw = "also das ist ein vollständiger test für einen echten fallback endpoint"
        let cleaned = "Das ist ein vollständiger Test für einen echten Fallback-Endpoint."
        var config = Config.Cleanup()
        config.fallbacks = [Config.Cleanup.Endpoint()]
        let incomplete = #"{"message":{"content":"Das ist ein vollständiger Test"},"done":false}"#
        let transport = StubCleanupTransport(
            streams: [[incomplete], [incomplete]], normalContent: cleaned
        )
        let service = CleanupService(config: config, transport: transport)
        service.notePrimarySuccess()
        var fallbackLabel: String?
        service.onFallbackEndpoint = { fallbackLabel = $0 }

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, cleaned)
        XCTAssertEqual(result.endpoint, config.fallbacks[0].label)
        XCTAssertEqual(fallbackLabel, config.fallbacks[0].label)
        XCTAssertEqual(transport.probeCallCount, 1)
        XCTAssertEqual(transport.normalCallCount, 1)
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
        // Der Live-Test prüft den Transport, nicht die schwankende Modellqualität:
        // Ändert das echte Modell ein Wort, muss die Worttreue-Sicherung ausdrücklich
        // auf Rohtext fallen. Ein gesetzter Endpoint beweist, dass der Stream mit
        // `done: true` vollständig ankam und erst danach geprüft wurde.
        XCTAssertEqual(result?.endpoint, cleanup.chain[0].label,
                       "Streaming-Transport muss abschließen: \(result?.fallbackReason ?? "")")
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

private func wavUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
}

/// Decoder nur für Byte-Level-Tests des tatsächlich hochgeladenen WAV-Formats;
/// Produktcode lädt Retry-Dateien unverändert als `Data` und braucht keinen zweiten
/// Decoder-Pfad.
private func wavSamples(_ data: Data) -> [Float] {
    stride(from: 44, to: data.count - 1, by: 2).map { offset in
        let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        return Float(Int16(bitPattern: bits)) / 32767
    }
}

private final class StubCleanupTransport: CleanupTransport {
    private let lock = NSLock()
    private var streams: [[String]]
    private let normalContent: String
    private(set) var streamCallCount = 0
    private(set) var probeCallCount = 0
    private(set) var normalCallCount = 0

    init(streams: [[String]], normalContent: String = "") {
        self.streams = streams
        self.normalContent = normalContent
    }

    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        lock.withLock {
            if probing { probeCallCount += 1 } else { normalCallCount += 1 }
        }
        let body: Data
        if probing {
            body = Data(#"{"version":"test"}"#.utf8)
        } else {
            body = try JSONSerialization.data(withJSONObject: [
                "message": ["content": normalContent]
            ])
        }
        return (body, httpResponse(for: request, status: 200))
    }

    func streamLines(for request: URLRequest, freshConnection: Bool) async throws
        -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let frames = lock.withLock {
            streamCallCount += 1
            return streams.isEmpty ? [] : streams.removeFirst()
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            frames.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return (stream, httpResponse(for: request, status: 200))
    }

    func sendWarmUp(_ request: URLRequest) {}

    private func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
