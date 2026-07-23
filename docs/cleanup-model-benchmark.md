# Bereinigungsmodell — Benchmark und Wächter-Entscheidung

Stand: 2026-07-23. Dieses Dokument hält fest, **warum** Stille Post ein bewusst
kleines, diszipliniertes Sprachmodell für die Textbereinigung nutzt und wie die
Worttreue-Prüfung („der Wächter") ausgelegt ist. Grundlage sind reproduzierbare
Messungen, keine Intuition — passend zur Projektregel „Wechsel nur evidenzbasiert".

Alle Beispiele sind bewusst kurze Teilformulierungen, keine vollständigen Diktate.

## Aufgabe zuerst: warum „größer" hier verliert

Die Bereinigung ist keine Textgenerierung, sondern eine eng begrenzte
Edit-in-place-Transformation: Füllwörter und Versprecher entfernen, Zeichensetzung
und Groß-/Kleinschreibung reparieren — und sonst **jedes Wort exakt so lassen**.

Genau dafür ist Modell-„Fähigkeit" oft kontraproduktiv. Große, stark auf
Hilfsbereitschaft trainierte Modelle haben einen starken Normalisierungs-Drang: sie
glätten Grammatik, pluralisieren, eindeutschen Lehnwörter. Für diese Aufgabe ist das
ein Fehler. Ein kleineres, diszipliniertes Modell hält die Anweisung „ändere nichts
außer X" von Natur aus besser ein.

## Messaufbau

- **Eingaben:** 35 reale, längen-gestreute Diktate aus dem lokalen Verlauf plus ein
  gezieltes Set „harter" Fälle (Fachbegriffe, Abkürzungen, Selbstkorrekturen,
  fehlerhaft transkribierte Wörter).
- **Treue:** exakte Portierung der App-Prüfung `sanityCheckFailure` — misst, was die
  App tatsächlich einfügt (bestanden) oder verwirft (Rohtext-Rückfall).
- **Putzqualität:** zwei unabhängige, lokale LLM-Richter, blind und ohne
  Selbstbewertung, bewerten Zeichensetzung und Treue auf einer Skala 1–5.
- **Geliefert:** der Entscheidungswert = Treue-Passrate × Putzqualität +
  Rückfallrate × Rohtext. Ein Modell, das brillant putzt, aber oft am Wächter
  scheitert, liefert beim Nutzer meist nur Rohtext.
- Alle Läufe: `temperature 0`, Reasoning aus, `num_ctx 16384`, lokal im eigenen Netz.

## Ergebnis (12 Modelle, nach gelieferter Qualität)

| Modell | Größe | Treue (tolerant) | Putzqual. | ⌀ s | Geliefert |
|---|---|---|---|---|---|
| gemma4:e4b-dictate¹ | 4B | 30/35 | 4,73 | 0,8 | 4,34 |
| gemma4:12b | 12B | 29/35 | 4,80 | 3,4 | 4,32 |
| gemma4:e4b | 4B | 28/35 | 4,73 | 1,1 | 4,18 |
| OpenEuroLLM-German | 8B | 27/35 | 4,61 | 9,5 | 4,02 |
| qwen3.6:35b | 35B | 24/35 | 4,80 | 2,8 | 3,92 |
| mistral-small3.2 | 24B | 25/35 | 4,66 | 2,8 | 3,90 |
| gemma4:26b | 26B | 25/35 | 4,63 | 1,1 | 3,88 |
| qwen3.5:9b | 9B | 24/35 | 4,54 | 1,6 | 3,74 |
| qwen2.5:7b-instruct | 7B | 24/35 | 4,46 | 1,0 | 3,69 |
| gemma3:4b | 4B | 25/35 | 3,88 | 0,9 | 3,42 |
| mistral-nemo:12b | 12B | 14/35 | 3,14 | 1,4 | 2,46 |
| aya-expanse:8b | 8B | 6/35 | 2,51 | 1,8 | 2,09 |

Kernaussagen:

- **Ein diszipliniertes kleines Modell gewinnt.** Seine Putzqualität liegt im Rauschen
  der 35B-Modelle (4,73 vs. 4,80), aber es ist am treuesten und mit Abstand am
  schnellsten. Größere Modelle „verbessern" ungefragt und scheitern dadurch öfter am
  Wächter — z. B. Übersetzen von „M-Dashes" zu „Gedankenstriche" oder Pluralisieren.
- **Nicht jedes kleine Modell taugt:** `gemma3:4b` (Platz 10) zeigt, dass es auf das
  konkrete Modell ankommt, nicht auf die Parameterzahl allein.

## Der ausgelieferte Default: `gemma4:e4b-it-qat`

¹ Das im Vergleich führende `gemma4:e4b-dictate` war ein **schlafendes lokales Artefakt**
aus einem OpenWhispr-Experiment (2026-06-23): kein trainiertes oder fein-getuntes Modell,
sondern nur ein `ollama create`-Wrapper um den öffentlichen `nvfp4`-Quant von `gemma4:e4b`
(rohes Template, sonst nichts). Es ist nicht aus der Registry beziehbar.

Ein Nachtest zeigte, dass **öffentlich pullbare** Quants es erreichen — bei gleichem
Basismodell und damit gleicher Qualität:

| Modell (pullbar) | Standard-Treue | Härtefall-Treue | Größe |
|---|---|---|---|
| **gemma4:e4b-it-qat** (QAT-4-Bit) | **31/35** | 8/14 | 6,1 GB |
| gemma4:e4b-nvfp4 | 28/35 | 8/14 | 8,8 GB |
| gemma4:e4b-dictate (lokal) | 30/35 | 8/14 | 9,6 GB |

Der Default ist deshalb das öffentlich beziehbare, kleine `gemma4:e4b-it-qat` (Googles
quantisierungs-bewusst trainierter 4-Bit-Build) — es erreicht bzw. übertrifft das
lokale Artefakt, ohne Mystery-Modell und ohne Modelltransfer.

## Harte Fälle: Fachbegriffe und Selbstkorrekturen

Ein zweiter Lauf mit technischen, holprigen Diktaten (Abkürzungen wie `IPTC`, `RTFD`,
`DMG`, Kennungen wie `num_ctx`, Selbstkorrekturen) zeigte zwei Dinge:

- **Fachbegriffe sind sicher.** Über alle Modelle hinweg wurde in keiner
  *ausgelieferten* Ausgabe ein Fachbegriff korrumpiert. Wo ein Modell einen Begriff
  „korrigieren" wollte (etwa `num_ctx` → `num_context`), fing der Wächter es ab und
  lieferte den Rohtext.
- **Treue schlägt Aufräumen.** Das disziplinierte Modell bewahrt Selbstkorrekturen
  wortgetreu — z. B. „zu GitHub gepusht, also nicht gepusht, sondern als Release
  hochgeladen". Aggressivere Modelle kürzten solche Passagen und verloren dabei
  bedeutungstragende Wörter; der Wächter kann das nicht fangen, weil Löschungen
  (zum Entfernen von Füllwörtern) erlaubt sein müssen.

Hinweis am Rande: In keinem der realen Diktate kam ein literales „äh/ähm" vor —
Whisper filtert diese Laute bereits vor der Bereinigung heraus. Die eigentliche
Putzarbeit ist deshalb Zeichensetzung, nicht Füllwort-Entfernung.

## Der tolerante Wächter

Der ursprüngliche Wächter verwarf **jede** Wortänderung. Das war zu streng: Er
verwarf auch berechtigte Reparaturen von Whisper-Artefakten und traf damit gerade die
langen Diktate, die am meisten Zeichensetzung brauchen (auf dem harten Langfall-Set
bestand selbst das beste Modell nur ~2 von 12).

Der neue Wächter richtet Roh- und Ausgabewörter aus (längste gemeinsame Teilfolge)
und beurteilt jede Lücke einzeln:

- **erlaubt:** Löschungen (Füllwörter) sowie eng begrenzte Mikro-Korrekturen an einer
  Ausrichtungslücke — reine Wort-Trennung/-Fusion (`dauer haft` → `dauerhaft`), ein
  einzelner Verhörer/Tippfehler (`olama` → `ollama`), eine kurze Flexionsendung
  (`ein` → `einen`).
- **verworfen (Rohtext-Rückfall):** Einfügungen, Umstellungen und echte Ersetzungen
  bzw. Übersetzungen (`verbinden` → `verwenden`, `M-Dashes` → `Gedankenstriche`);
  außerdem zu viele Mikro-Korrekturen in Summe (schleichendes Umschreiben).
- **unantastbar:** Tokens mit Ziffern (Modell-/Versionskennungen wie `426b`, `id3`)
  bekommen keine Tippfehler-Toleranz — dort ist schon ein Zeichen bedeutungstragend.

Wirkung auf dem realen Set: Die Treue-Passrate des besten Modells stieg von 22/35 auf
30/35, auf den harten Langfällen von 2/12 auf 8/12 — und der Umbau half jedem Modell.
Die Längenkorridor-Prüfung bleibt als zusätzliche Sicherheitsgrenze bestehen.
