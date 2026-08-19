import XCTest
import AVFoundation
import AppKit
import Network
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

    func testDiskAndNetworkWavCarryTheSameBytes() throws {
        // Dasselbe Audio geht auf zwei Wegen weiter: als WAV per HTTP an den
        // whisper-server und fortlaufend als Datei auf Platte. „Erneut
        // transkribieren“ liest später die Datei — sie muss genau das Audio
        // enthalten, das das Live-Diktat schon gesehen hat. Beide Wege benutzen
        // deshalb dieselbe Umrechnung; dieser Test hält sie zusammen.
        let samples: [Float] = [0, 0.5, -0.5, 0.123, -0.987,
                                1, -1, 2, -2]  // die letzten vier prüfen die Begrenzung
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-parity-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url)
        try writer.append(samples)
        try writer.finish()

        XCTAssertEqual(try Data(contentsOf: url), WavCodec.wavData(from: samples),
                       "Datei und Netz-WAV müssen Byte für Byte übereinstimmen")
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

    // MARK: Plausibilitäts- und Worttreue-Abgleich der Bereinigung

    /// Kurzform: Abgleich ohne Wörterbuch — akzeptiert die Ausgabe unverändert?
    private func acceptsUnchanged(raw: String, cleaned: String) -> Bool {
        CleanupService.reconcile(raw: raw, cleaned: cleaned)
            == .accepted(text: cleaned, revertedClauses: 0)
    }

    /// Kurzform: Abgleich ohne Wörterbuch — komplett verworfen (Rohtext-Fallback)?
    private func rejects(raw: String, cleaned: String) -> Bool {
        if case .rejected = CleanupService.reconcile(raw: raw, cleaned: cleaned) {
            return true
        }
        return false
    }

    func testReconcileAcceptsNormalCleanup() {
        let raw = "also ähm ich wollte halt mal kurz sagen dass das mit dem diktieren noch nicht so richtig schnell läuft"
        let cleaned = "Ich wollte mal kurz sagen, dass das mit dem Diktieren noch nicht so richtig schnell läuft."
        XCTAssertTrue(acceptsUnchanged(raw: raw, cleaned: cleaned))
    }

    func testReconcileRejectsMassiveShortening() {
        // Simuliert den realen Fehlerfall: Modell kürzt langes Diktat auf einen Satz.
        let raw = String(repeating: "das ist ein längerer diktierter satz mit vielen wörtern ", count: 10)
        XCTAssertTrue(rejects(raw: raw, cleaned: "Okay."))
    }

    func testReconcileRejectsShorteningHiddenByLateAnchors() {
        // Bei Gleichstand muss die Anker-Suche die FRÜHESTE Rohtext-Ausrichtung
        // wählen. Sonst ankert „Wir machen“ an den SPÄTEN Vorkommen: Der ganze
        // Anfang gälte dann als erlaubte Löschung und „morgen“ -> „sorgen“ als
        // Tippfehler — eine stark gekürzte und inhaltlich veränderte Ausgabe
        // käme durch.
        XCTAssertTrue(rejects(
            raw: "wir machen heute wir testen jetzt wir machen morgen",
            cleaned: "Wir machen Sorgen."))
    }

    func testReconcileRejectsOutputWithoutASingleWord() {
        // Verliert die Ausgabe jedes Wort, ist das keine Bereinigung, sondern
        // der Totalverlust des Diktats. Der Längenkorridor allein lässt es bei
        // kurzen Eingaben durch („kein“ -> „.“ sind 25 %).
        XCTAssertTrue(rejects(raw: "kein", cleaned: "."))
        XCTAssertTrue(rejects(raw: "nur", cleaned: "."))
    }

    func testReconcileRejectsAnswering() {
        // Simuliert: Modell "beantwortet" das Diktat statt zu putzen (Ausgabe wächst stark).
        let raw = "welche lokalen modelle empfiehlst du für textbereinigung"
        let cleaned = String(repeating: "Hier ist eine Tabelle empfohlener Modelle … ", count: 20)
        XCTAssertTrue(rejects(raw: raw, cleaned: cleaned))
    }

    func testReconcileAllowsShortInputs() {
        // Kurze Diktate dürfen stark schrumpfen ("ähm ja Punkt" -> "Ja.").
        XCTAssertTrue(acceptsUnchanged(raw: "ähm ja punkt", cleaned: "Ja."))
    }

    func testReconcileRevertsOnlyTheChangedClause() {
        // DER Kernfall der neuen Prüfung: Ein verändertes Wort verwirft nicht mehr
        // die ganze Bereinigung, sondern setzt nur den betroffenen Satzteil zurück —
        // die korrekten Korrekturen der übrigen Satzteile bleiben erhalten.
        let result = CleanupService.reconcile(
            raw: "das machen wir ähm mit dem tool außerdem verbinden wir die geräte",
            cleaned: "Das machen wir mit dem Tool, außerdem verwenden wir die Geräte."
        )
        XCTAssertEqual(result, .accepted(
            text: "Das machen wir mit dem Tool, außerdem verbinden wir die geräte.",
            revertedClauses: 1
        ))
    }

    func testReconcileRevertKeepsSeparatorsInsideRevertedClause() {
        // Die Rücksetzung baut den Satzteil aus dem Original-Substring wieder
        // auf — Schräg- und Bindestriche ("CI/CD-Workflow") dürfen dabei nicht
        // zu Leerzeichen zerfallen (früherer Fehler: "CI CD Workflow").
        let result = CleanupService.reconcile(
            raw: "wir bauen den CI/CD-Workflow ähm morgen um außerdem testen wir alles",
            cleaned: "Wir reparieren den CI/CD-Workflow morgen um, außerdem testen wir alles."
        )
        XCTAssertEqual(result, .accepted(
            text: "wir bauen den CI/CD-Workflow ähm morgen um, außerdem testen wir alles.",
            revertedClauses: 1
        ))
    }

    func testReconcileHandlesLongDictationsWithLinearMemory() {
        // Regressionstest für den Speicher-Umbau (Hirschberg statt voller
        // LCS-Tabelle, die bei Mehrtausend-Wort-Diktaten Hunderte MB kostete):
        // Ein langes Diktat muss zügig durchlaufen und Füllwort-Löschungen
        // weiterhin normal akzeptieren.
        let vocabulary = ["alpha", "beta", "gamma", "delta", "epsilon",
                          "zeta", "eta", "theta", "iota", "kappa"]
        var rawWords: [String] = []
        var cleanWords: [String] = []
        for index in 0..<2400 {
            let word = vocabulary[index % vocabulary.count]
            rawWords.append(word)
            cleanWords.append(word)
            if index % 7 == 0 { rawWords.append("ähm") }  // Füllwörter, die gelöscht werden
        }
        let result = CleanupService.reconcile(raw: rawWords.joined(separator: " "),
                                              cleaned: cleanWords.joined(separator: " "))
        XCTAssertEqual(result, .accepted(text: cleanWords.joined(separator: " "),
                                         revertedClauses: 0))
    }

    func testReconcileRejectsWhenMostClausesChanged() {
        // Ist mehr als die Hälfte der Satzteile betroffen, ist die Ausgabe insgesamt
        // nicht vertrauenswürdig -> kompletter Rohtext-Fallback wie früher.
        XCTAssertTrue(rejects(
            raw: "Bitte verbinden wir die beiden Geräte morgen",
            cleaned: "Bitte verwenden wir die beiden Geräte morgen."
        ))
    }

    func testReconcileRejectsWordReordering() {
        // Auch wenn exakt dieselben Wörter vorkommen, bleibt ihre Reihenfolge Teil
        // des Diktats und darf nicht vom Bereinigungsmodell geglättet werden.
        XCTAssertTrue(rejects(
            raw: "Heute möchte ich den langen Bericht in Ruhe fertig schreiben",
            cleaned: "Den langen Bericht möchte ich heute in Ruhe fertig schreiben."
        ))
    }

    func testReconcileAllowsOrderedWordDeletion() {
        XCTAssertTrue(acceptsUnchanged(
            raw: "Also ich ich wollte ähm heute den Bericht schreiben",
            cleaned: "Ich wollte heute den Bericht schreiben."
        ))
    }

    func testReconcileRejectsEmpty() {
        XCTAssertTrue(rejects(raw: "hallo welt", cleaned: ""))
    }

    func testReconcileRejectsMarkdownStructures() {
        // Realer Fehlerfall (bei einem anderen Diktat-Tool beobachtet): Das Modell
        // "beantwortet" das Diktat und erzeugt Codeblöcke/Beispiel-Befehle.
        let raw = "bitte noch ein startgeräusch ergänzen das kannst du mit dem generierungstool machen"
        let answered = "Bitte noch ein Startgeräusch ergänzen.\n```\ntool generate --name blup\n```"
        XCTAssertTrue(rejects(raw: raw, cleaned: answered))
        // Aber: Diktiert jemand selbst über Markdown, dürfen vorhandene Marker bleiben.
        XCTAssertTrue(acceptsUnchanged(
            raw: "der code steht in einem ```-Block ähm im readme",
            cleaned: "Der Code steht in einem ```-Block im README."))
    }

    // MARK: Tolerante Treueprüfung — legitime Mikro-Korrekturen zulassen

    func testReconcileAllowsWhisperCompoundSplit() {
        // Whisper zerhackt Komposita an Sprechpausen; das Zusammenfügen ist kein
        // Umschreiben und darf nicht länger den Rohtext-Fallback auslösen.
        XCTAssertTrue(acceptsUnchanged(
            raw: "das soll dann dauer haft geladen bleiben",
            cleaned: "Das soll dann dauerhaft geladen bleiben."))
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich mache das über einen screens hot",
            cleaned: "Ich mache das über einen Screenshot."))
    }

    func testReconcileAllowsSingleTypoFix() {
        // Ein einzelner Verhörer/Tippfehler (Editierabstand 1) ist eine Korrektur,
        // keine Bedeutungsänderung.
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich nutze ein lokales olama modell",
            cleaned: "Ich nutze ein lokales Ollama-Modell."))
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich haabe den bericht geschrieben",
            cleaned: "Ich habe den Bericht geschrieben."))
    }

    func testReconcileAllowsShortInflectionEnding() {
        // Kurze Flexionsendung (Präfix + max. 2 Zeichen) korrigiert Grammatik,
        // ohne das Wort auszutauschen.
        XCTAssertTrue(acceptsUnchanged(
            raw: "wir hätten gerne ein logging modus",
            cleaned: "Wir hätten gerne einen Logging-Modus."))
        XCTAssertTrue(acceptsUnchanged(
            raw: "weniger vorhersehbare formulierung bitte",
            cleaned: "Weniger vorhersehbare Formulierungen, bitte."))
    }

    func testReconcileAllowsSoundAlikeWords() {
        // Gleich klingende Wörter (Kölner Phonetik) sind Hörvarianten desselben
        // Diktats: "Rack" -> "RAG" ist genau die gewünschte Korrektur.
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich möchte mehr mit rack machen also retrieval augmented generation",
            cleaned: "Ich möchte mehr mit RAG machen, also Retrieval Augmented Generation."))
    }

    func testReconcileAllowsDictionaryTermThatSoundsSimilar() {
        // Wörterbuch-Begriff: "Mini Macs" klingt ähnlich wie "MiniMax" (Lautcode-
        // Abstand 1) — mit Eintrag erlaubt, ohne Eintrag nicht.
        let raw = "mein mini macs abo läuft diese woche aus und wird nicht verlängert"
        let cleaned = "Mein MiniMax Abo läuft diese Woche aus und wird nicht verlängert."
        XCTAssertEqual(
            CleanupService.reconcile(raw: raw, cleaned: cleaned,
                                     dictionary: CleanupService.normalizedDictionary(["MiniMax"])),
            .accepted(text: cleaned, revertedClauses: 0)
        )
        // Ohne Wörterbuch bleibt es eine unzulässige Ersetzung (ein Satzteil,
        // also kompletter Fallback).
        XCTAssertTrue(rejects(raw: raw, cleaned: cleaned))
    }

    func testReconcileStillRejectsTranslationAndSynonyms() {
        // Übersetzung eines Fachbegriffs bleibt eine Bedeutungsänderung -> Fallback.
        XCTAssertTrue(rejects(
            raw: "bitte weniger m dashes verwenden",
            cleaned: "Bitte weniger Gedankenstriche verwenden."))
        // Synonym mit größerem Abstand (und anderem Klang) bleibt verboten.
        XCTAssertTrue(rejects(
            raw: "das ist die hochqualitätigste variante",
            cleaned: "Das ist die hochwertigste Variante."))
    }

    func testReconcileProtectsTechnicalTokensWithDigits() {
        // Modell-/Versionskennungen dürfen NIE als "Tippfehler" durchgehen — ein
        // Zeichen Unterschied ist hier bedeutungstragend (426b ≠ 426c).
        XCTAssertTrue(rejects(
            raw: "wir nehmen das gemma 426b modell",
            cleaned: "Wir nehmen das Gemma 426c Modell."))
        XCTAssertTrue(rejects(
            raw: "die tags stehen im id3 header",
            cleaned: "Die Tags stehen im ID4 Header."))
        // Unveränderte Ziffern-Kennung darf drumherum weiter geputzt werden (hier:
        // Füllwort entfernen), solange die Kennung selbst exakt erhalten bleibt.
        XCTAssertTrue(acceptsUnchanged(
            raw: "das ist halt das gemma 426b modell",
            cleaned: "Das ist das Gemma 426b Modell."))
    }

    func testReconcileRejectsNegationFlipDespiteSingleEdit() {
        // "kein" -> "ein" ist nur EIN Buchstabe Unterschied und rutschte deshalb
        // durch die Tippfehler-Toleranz — dreht die Aussage aber komplett um.
        // Solche sinnumkehrenden Funktionswörter stehen jetzt auf der Sperrliste.
        XCTAssertTrue(rejects(
            raw: "ich habe damit kein problem",
            cleaned: "Ich habe damit ein Problem."))
        // Auch die Gegenrichtung: Eine Verneinung darf nicht neu entstehen.
        XCTAssertTrue(rejects(
            raw: "wir haben da ein problem",
            cleaned: "Wir haben da kein Problem."))
        // Gleichklang schützt nicht davor: "ohne" und "ahne" haben denselben
        // Kölner Lautcode und wären sonst als Hörvariante durchgegangen.
        XCTAssertTrue(rejects(
            raw: "das läuft ohne fehler",
            cleaned: "Das läuft ahne Fehler."))
    }

    func testReconcileRevertsOnlyTheNegationClause() {
        // Die Sperrliste wirkt wie jede andere unzulässige Ersetzung: Nur der
        // betroffene Satzteil geht auf den Rohtext zurück, der Rest bleibt geputzt.
        let result = CleanupService.reconcile(
            raw: "das ist kein problem, wir machen das ähm morgen",
            cleaned: "Das ist ein Problem, wir machen das morgen."
        )
        XCTAssertEqual(result, .accepted(
            text: "das ist kein problem, wir machen das morgen.",
            revertedClauses: 1
        ))
    }

    func testReconcileStillAllowsInflectionOfNegations() {
        // Die Sperrliste darf die gewollte Rettung nicht kaputtmachen: Innerhalb
        // derselben Wortfamilie bleibt die reine Beugung erlaubt ("kein" -> "keinen").
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich habe da kein bock drauf",
            cleaned: "Ich habe da keinen Bock drauf."))
        // Und ein Wort, das nur zufällig neben einer Verneinung steht, bleibt
        // ganz normal korrigierbar (Tippfehler-Toleranz unverändert).
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich nutze kein olama modell",
            cleaned: "Ich nutze kein Ollama-Modell."))
    }

    func testReconcileCatchesSwallowedNegation() {
        // Die Sperrliste griff anfangs nur bei ERSETZUNGEN. Verschluckt das Modell
        // die Verneinung ganz, sah der Abgleich nur eine Löschung — und Löschungen
        // sind als Füllwort-Entfernung erlaubt. Für ein Diktat ist eine
        // weggelassene Verneinung aber genauso sinnverkehrend wie eine ersetzte.
        XCTAssertTrue(rejects(
            raw: "ich habe das nicht gemacht",
            cleaned: "Ich habe das gemacht."))
        // Auch die Reichweite-Wörter der Liste zählen, nicht nur die Verneinung.
        XCTAssertTrue(rejects(
            raw: "das war nur ein test",
            cleaned: "Das war ein Test."))
    }

    func testReconcileRevertsOnlyTheClauseWithTheSwallowedNegation() {
        // Die verschluckte Verneinung hat keinen eigenen Ausgabe-Index; trotzdem
        // muss die Rücksetzung chirurgisch bleiben: nur der Satzteil, aus dem sie
        // verschwunden ist, geht auf den Rohtext zurück — der zweite bleibt geputzt
        // (dort wird das Füllwort "ähm" weiterhin entfernt).
        let result = CleanupService.reconcile(
            raw: "das geht so nicht, wir machen das ähm morgen",
            cleaned: "Das geht so, wir machen das morgen."
        )
        XCTAssertEqual(result, .accepted(
            text: "das geht so nicht, wir machen das morgen.",
            revertedClauses: 1
        ))
    }

    func testReconcileRevertsTheClauseTheNegationBelongedTo() {
        // Die verschluckte Verneinung stand HINTER einer Satzteil-Grenze. Sie
        // trotzdem dem Ausgabe-Wort DAVOR zuzuschlagen setzte den falschen —
        // nämlich unveränderten — ersten Satz zurück, und die Verneinung hing
        // als Rest an dessen Ende („erster satz. nicht Machen wir das.“).
        let result = CleanupService.reconcile(
            raw: "erster satz. nicht machen wir das",
            cleaned: "Erster Satz. Machen wir das."
        )
        XCTAssertEqual(result, .accepted(
            text: "Erster Satz. nicht machen wir das.",
            revertedClauses: 1
        ))
    }

    func testReconcileFindsNegationBehindFillerAndInternalBoundary() {
        // Die Löschungslücke enthält mehr als die Verneinung. Entscheidend ist
        // die Satzgrenze INNERHALB der Lücke: `nicht` gehört zum zweiten Satz,
        // das Füllwort davor darf trotzdem verschwinden.
        let result = CleanupService.reconcile(
            raw: "erster satz ähm. nicht machen wir das",
            cleaned: "Erster Satz. Machen wir das."
        )
        XCTAssertEqual(result, .accepted(
            text: "Erster Satz. nicht machen wir das.",
            revertedClauses: 1
        ))

        // Die Satzgrenze kann auch VOR dem Füllwort liegen. Sie gehört trotzdem
        // zur selben Löschungslücke und ordnet `nicht` dem zweiten Satz zu.
        let boundaryBeforeFiller = CleanupService.reconcile(
            raw: "erster satz. ähm nicht machen wir das",
            cleaned: "Erster Satz. Machen wir das."
        )
        XCTAssertEqual(boundaryBeforeFiller, .accepted(
            text: "Erster Satz. nicht machen wir das.",
            revertedClauses: 1
        ))
    }

    func testReconcileCatchesSwallowedEnglishNegation() {
        // `whisper.language` ist standardmäßig „auto“, Englisch ist ausdrücklich
        // unterstützt: Eine weggelassene englische Verneinung dreht die Aussage
        // genauso um wie eine deutsche.
        XCTAssertTrue(rejects(raw: "i did not approve this",
                              cleaned: "I did approve this."))
        // Verkürzte Form: Der Apostroph trennt die Wörter, im Diktat steht
        // deshalb „didn“ + „t“.
        XCTAssertTrue(rejects(raw: "i didn't approve this",
                              cleaned: "I did approve this."))
        // Bei `can't` bleibt der Stamm `can` in beiden Fassungen als Anker
        // stehen. Das einzelne `t` hinter dem Apostroph trägt die Verneinung.
        for raw in ["i can't approve this", "i can’t approve this"] {
            XCTAssertTrue(rejects(raw: raw, cleaned: "I can approve this."), raw)
        }
        XCTAssertTrue(rejects(raw: "we have no time for that",
                              cleaned: "We have time for that."))
        // Ohne Verneinung bleibt die englische Bereinigung ganz normal erlaubt.
        XCTAssertTrue(acceptsUnchanged(raw: "so i did approve this yesterday",
                                       cleaned: "I did approve this yesterday."))
    }

    func testReconcileTreatsEnglishContractionsAsOneNegation() {
        // Die Kurzform und die ausgeschriebene Form sind bedeutungsgleich. Der
        // Apostroph darf nicht zwei Verneinungsschlüssel aus einem Wort machen.
        for (raw, cleaned) in [
            ("i didn't approve this", "I did not approve this."),
            ("it doesn't work", "It does not work."),
            ("i can't approve this", "I can not approve this."),
            ("i can’t approve this", "I cannot approve this."),
        ] {
            XCTAssertTrue(acceptsUnchanged(raw: raw, cleaned: cleaned), raw)
        }
    }

    func testReconcileStillAllowsDeletingFillersAndStutteredNegations() {
        // Kernbedingung der Erweiterung: Gewöhnliche Löschungen bleiben erlaubt.
        XCTAssertTrue(acceptsUnchanged(
            raw: "also ähm das ist halt quasi fertig",
            cleaned: "Das ist fertig."))
        // Und eine gestotterte Verneinung darf entdoppelt werden: Die Aussage
        // ändert sich nicht, weil dasselbe Wort direkt daneben stehen bleibt.
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich habe das nicht nicht gemacht",
            cleaned: "Ich habe das nicht gemacht."))
    }

    func testReconcileRejectsManyMicroEditsAsRewrite() {
        // Jede Einzeländerung wäre klein, aber in Summe ist es ein Umschreiben:
        // Das Gesamtbudget muss greifen.
        XCTAssertTrue(rejects(
            raw: "alpha ein beta ein gamma ein delta ein epsilon ein zeta",
            cleaned: "Alpha einen, Beta einen, Gamma einen, Delta einen, Epsilon einen, Zeta."))
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
    func testUndeletableRecordingStillDeliversTheDictation() async throws {
        // Der Text ist transkribiert, bereinigt und im Verlauf gespeichert; nur
        // das Wegraeumen der Diagnoseaufnahme scheitert (hier: schreibgeschuetzter
        // Ordner). Das ist ein Aufraeumproblem — das fertige Diktat gehoert
        // trotzdem ausgeliefert, sonst faellt es wegen einer Nebensache unter den
        // Tisch. Der Fehler wird zusaetzlich gemeldet.
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sp-undeletable-\(UUID())")
        let blocked = baseDir.appendingPathComponent("gesperrt")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let wavURL = blocked.appendingPathComponent("aufnahme.wav")
        try Data("RIFF".utf8).write(to: wavURL)
        // Ohne Schreibrecht am Ordner laesst sich die Datei darin nicht loeschen.
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: blocked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: baseDir)
        }

        let history = HistoryStore(baseDir: baseDir.appendingPathComponent("verlauf"))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavURL.path),
                      "die Aufnahme bleibt liegen — genau darum geht es")
        XCTAssertNotNil(reportedError, "das gescheiterte Aufraeumen muss gemeldet werden")
    }

    @MainActor
    func testResultIsDeliveredOnMainThread() async throws {
        // Regression 0.8.13: finishSession ist nonisolated async und läuft off-main;
        // onResult fasst aber im App-Callback AppKit an (Overlay-Panel). Lieferte die
        // Engine off-main aus, brach AppKit ab macOS 26 hart ab. Der Vertrag lautet
        // "onResult auf Main-Thread" — genau das prüft dieser Test.
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
        XCTAssertEqual(chain[1].model, "gemma4:e4b-it-qat")
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

    func testForeignErrorTextIsShortenedBeforeItReachesTheHistory() {
        // Diese Beschreibungen wandern über `fallbackReason` beziehungsweise
        // `errorMessage` dauerhaft in die Verlaufsdatei. Der Text kommt vom
        // Gegenüber — eine Fehlerseite eines Proxys oder ein beliebig langer
        // `error`-Wert im Stream darf den Verlauf nicht fluten. Geprüft werden
        // alle drei Wege gemeinsam, damit keiner die gemeinsame Grenze verliert.
        let flood = String(repeating: "x", count: 5000)
        let described: [String] = [
            CleanupService.CleanupError.serverError(body: flood).localizedDescription,
            CleanupService.CleanupError.providerError(flood).localizedDescription,
            WhisperClient.WhisperError.serverError(body: flood).localizedDescription,
        ]
        for text in described {
            XCTAssertEqual(text.filter { $0 == "x" }.count,
                           DiagnosticText.maxForeignCharacters,
                           "fremder Fehlertext muss gekürzt ankommen: \(text.prefix(40))")
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

        // Fallback-Rohtext läuft durch die deterministische Nachstufe
        // (hier: nur Großschreibung am Satzanfang).
        XCTAssertEqual(result.text, "Das" + raw.dropFirst(3))
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

    func testPrimaryIdleTimeoutRetriesPatientlyWhileModelLoads() async {
        // Kaltstart des Bereinigungsmodells: Der Server nimmt die Verbindung an
        // und schweigt, bis das Leerlauf-Timeout des Streaming-Pfads zuschlaegt
        // (gemessen: 11,5 s Ladezeit gegen 10 s Geduld). Ein zweiter Stream mit
        // derselben kurzen Geduld liefe genauso ins Leere — erwartet wird die
        // geduldige Komplett-Antwort, nachdem die Probe den Server als lebendig
        // bestaetigt hat.
        let raw = "also das ist ein vollständiger test für ein kalt startendes modell"
        let cleaned = "Das ist ein vollständiger Test für ein kalt startendes Modell."
        let transport = StubCleanupTransport(
            outcomes: [.failure(URLError(.timedOut))], normalContent: cleaned
        )
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        service.notePrimarySuccess()
        var retryReported = false
        service.onPrimaryRetry = { retryReported = true }

        let result = await service.clean(raw)

        XCTAssertEqual(result.text, cleaned)
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.endpoint, Config.Cleanup().chain[0].label)
        XCTAssertTrue(retryReported)
        XCTAssertEqual(transport.streamCallCount, 1,
                       "kein zweiter Stream mit derselben kurzen Geduld")
        XCTAssertEqual(transport.probeCallCount, 1, "eine Probe klaert: lebt der Server?")
        XCTAssertEqual(transport.normalCallCount, 1, "geduldige Komplett-Antwort")
    }

    func testPrimaryIdleTimeoutWithDeadServerSkipsSecondAttempt() async {
        // Gleiche Ausgangslage, aber der Server ist wirklich weg. Dann darf der
        // geduldige Versuch NICHT laufen: Er wuerde bis zu 120 s kosten, bevor
        // die Kette weiterzieht.
        let raw = "also das ist ein vollständiger test für einen wirklich toten endpoint"
        let transport = StubCleanupTransport(
            outcomes: [.failure(URLError(.timedOut))], probeSucceeds: false
        )
        let service = CleanupService(config: Config.Cleanup(), transport: transport)
        service.notePrimarySuccess()

        let result = await service.clean(raw)

        XCTAssertTrue(result.usedFallback)
        XCTAssertNil(result.endpoint)
        XCTAssertEqual(transport.streamCallCount, 1)
        XCTAssertEqual(transport.normalCallCount, 0,
                       "kein 120-s-Versuch gegen einen toten Server")
        XCTAssertTrue(result.fallbackReason?.contains("127.0.0.1:11434") ?? false,
                      "der tote Endpoint muss im Grund stehen: \(result.fallbackReason ?? "")")
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
        // Auch ohne erreichbaren Endpoint greift die deterministische Nachstufe.
        XCTAssertEqual(result?.text, "Das" + raw.dropFirst(3))
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
    /// Was der naechste Streaming-Aufruf liefern soll: die geplanten NDJSON-Zeilen
    /// oder einen Transportfehler (etwa das Leerlauf-Timeout des Primaerpfads).
    enum StreamOutcome {
        case frames([String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcomes: [StreamOutcome]
    private let normalContent: String
    private let probeSucceeds: Bool
    private(set) var streamCallCount = 0
    private(set) var probeCallCount = 0
    private(set) var normalCallCount = 0

    convenience init(streams: [[String]], normalContent: String = "") {
        self.init(outcomes: streams.map { .frames($0) }, normalContent: normalContent)
    }

    init(outcomes: [StreamOutcome], normalContent: String = "", probeSucceeds: Bool = true) {
        self.outcomes = outcomes
        self.normalContent = normalContent
        self.probeSucceeds = probeSucceeds
    }

    func data(for request: URLRequest, probing: Bool) async throws -> (Data, URLResponse) {
        lock.withLock {
            if probing { probeCallCount += 1 } else { normalCallCount += 1 }
        }
        // Ein toter Server meldet sich auch bei der Probe nicht.
        if probing, !probeSucceeds { throw URLError(.cannotConnectToHost) }
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
        let outcome = lock.withLock {
            streamCallCount += 1
            return outcomes.isEmpty ? StreamOutcome.frames([]) : outcomes.removeFirst()
        }
        let frames: [String]
        switch outcome {
        case .failure(let error): throw error
        case .frames(let planned): frames = planned
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
