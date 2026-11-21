import XCTest
@testable import StillePostCore

final class TranscriptReconciliationTests: XCTestCase {
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
        let cleaned = "Also, ich wollte halt mal kurz sagen, dass das mit dem Diktieren noch nicht so richtig schnell läuft."
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
        // Auch kurze Diktate dürfen eindeutige Zögerlaute verlieren.
        XCTAssertTrue(acceptsUnchanged(raw: "ähm ja", cleaned: "Ja."))
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
            raw: "Ähm ich ich wollte ähm heute den Bericht schreiben",
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
            raw: "das ist ähm das gemma 426b modell",
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
                                       cleaned: "So, I did approve this yesterday."))
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
        // Eindeutige Sprechpausen dürfen weiterhin verschwinden.
        XCTAssertTrue(acceptsUnchanged(
            raw: "ähm das ist äh fertig",
            cleaned: "Das ist fertig."))
        // Und eine gestotterte Verneinung darf entdoppelt werden: Die Aussage
        // ändert sich nicht, weil dasselbe Wort direkt daneben stehen bleibt.
        XCTAssertTrue(acceptsUnchanged(
            raw: "ich habe das nicht nicht gemacht",
            cleaned: "Ich habe das nicht gemacht."))
    }

    func testReconcileProtectsAmountsDatesAndAmbiguousFillers() {
        for (raw, cleaned) in [
            ("ich überweise hundert euro", "Ich überweise Euro."),
            ("I approve this tomorrow", "I approve this."),
            ("ich fahre um zehn uhr", "Ich fahre zehn Uhr."),
            ("das ist quasi fertig", "Das ist fertig."),
            ("das ist halt fertig", "Das ist fertig."),
            ("I also approve this", "I approve this."),
            ("so i did approve this", "I did approve this."),
            ("Ich fahre nach Baden-Baden", "Ich fahre nach Baden."),
            ("Termin 10/10", "Termin 10."),
        ] { XCTAssertTrue(rejects(raw: raw, cleaned: cleaned), raw) }
    }

    func testReconcileAllowsEnglishHesitationsAndImmediateRepetition() {
        XCTAssertTrue(acceptsUnchanged(raw: "uh I I approve this tomorrow",
                                       cleaned: "I approve this tomorrow."))
        XCTAssertTrue(rejects(raw: "nicht, nicht machen", cleaned: "Nicht machen."))
    }

    func testReconcileRevertsOnlyTheClauseWithDroppedAmount() {
        XCTAssertEqual(CleanupService.reconcile(
            raw: "ich überweise hundert euro. danach schicke ich den beleg",
            cleaned: "Ich überweise Euro. Danach schicke ich den Beleg."
        ), .accepted(text: "ich überweise hundert euro. Danach schicke ich den Beleg.",
                     revertedClauses: 1))
    }

    func testReconcileRejectsManyMicroEditsAsRewrite() {
        // Jede Einzeländerung wäre klein, aber in Summe ist es ein Umschreiben:
        // Das Gesamtbudget muss greifen.
        XCTAssertTrue(rejects(
            raw: "alpha ein beta ein gamma ein delta ein epsilon ein zeta",
            cleaned: "Alpha einen, Beta einen, Gamma einen, Delta einen, Epsilon einen, Zeta."))
    }
}
