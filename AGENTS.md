# Stille Post — dauerhafte Projektregeln

Stand: 2026-07-16. Diese Datei enthält nur Regeln und Fakten, die ein Agent beim
Start zuverlässig braucht. Produktgeschichte und erledigte Arbeit gehören in
`CHANGELOG.md`, Releases oder abgeschlossene Tasks; offene Arbeit in den Backlog.

## Zweck und Einstieg

Stille Post ist eine lokale macOS-Diktier-App mit Swift-GUI und CLI. Audio wird
lokal durch Whisper transkribiert; nur der fertige Text darf optional zur
sprachlichen Bereinigung an konfigurierte LLM-Endpunkte gehen.

- `Sources/StillePostCore/`: testbarer Kern für Aufnahme, VAD, Whisper,
  Bereinigung, Historie und Konfiguration.
- `Sources/StillePost/`: AppKit/SwiftUI-App, Carbon-Hotkey, Overlay, Verlauf und
  Einstellungen.
- `Sources/stillepost-cli/`: Diagnose, Transkription, Bereinigung, Historie und
  Konfigurationsbefehle.
- `Tests/`: SwiftPM-Tests. Das Verzeichnis muss bestehen bleiben, damit SwiftPM
  den Test-Target korrekt erkennt.
- Drei Einstiegspunkte im Repo-Root, klar getrennt: `./build.sh` baut nur nach
  `build/`, `./install.sh` baut + notarisiert + installiert nach `/Applications`,
  `./release.sh` baut + notarisiert + packt das geprüfte Release-DMG und
  installiert nie. Die eigentliche Bau- und Signaturlogik bleibt in
  `scripts/build-app.sh`, das DMG erzeugt `scripts/create-dmg.sh`.
- `scripts/e2e-test.sh`: lokaler End-to-End-Lauf; `VERSION`: Produktversion.

## Verbindliche Architektur

Der Ablauf ist: Aufnahme → VAD/Segmentierung → laufende lokale Transkription →
Zusammenfügen → genau eine Bereinigung über den vollständigen Text → Einfügen und
Historie. Die Bereinigung darf nie pro Streaming-Segment erfolgen, weil dadurch
Kontext, Satzgrenzen und konsistente Zeichensetzung verloren gehen.

- Whisper-Modell: `large-v3-turbo`. Einen Modellwechsel nur nach reproduzierbarer
  Qualitäts- und Latenzmessung vornehmen.
- Bereinigungsmodell ist `gemma4:e4b-it-qat` (öffentlich beziehbar, ~6 GB; gewann den
  Benchmark in `docs/cleanup-model-benchmark.md`). `think: false` bleibt gesetzt. Ein
  diszipliniertes kleines Modell schlägt hier die großen — Wechsel nur evidenzbasiert.
- `num_ctx` explizit auf 16384 setzen. Warm-up und Chat müssen denselben Wert
  verwenden; unterschiedliche Kontextgrößen können getrennte Modellinstanzen laden.
- Primärer Endpunkt: direkter Streaming-Request. Scheitert er, folgt genau ein
  sofortiger zweiter Versuch — dessen Form richtet sich nach der Ursache:
  - Abgebrochener Stream, ungültiger Frame, Providerfehler oder Verbindungsfehler
    („Modell wird neu geladen“ ist der häufigste und geht beim zweiten Versuch
    durch): Wiederholung als Stream über eine frische Sitzung.
  - Leerlauf-Timeout, also 10 s ohne ein einziges Häppchen: Der Server hat die
    Verbindung angenommen und schweigt — typischerweise lädt er gerade das Modell
    (gemessen: 11,5 s für 6 GB nach dem Booten, auf RAM-knappen Rechnern ein
    Vielfaches). Ein zweiter Stream mit derselben Geduld liefe genauso ins Leere.
    Deshalb entscheidet hier die schnelle Erreichbarkeitsprobe: antwortet der
    Server, folgt die geduldige Komplett-Antwort ohne Leerlauf-Timeout; antwortet
    er nicht, geht es sofort zum nächsten Endpunkt, statt weitere 10 s zu
    verschenken.

  Danach die geordnete Fallback-Kette. Fallback-Probes bleiben non-streaming;
  keine parallelen oder gehedgten Requests.
- Fallback-Semantik: Netzwerk-/Dienstfehler → nächster Endpunkt. Plausibilitätsfehler
  des bereinigten Textes → den Rohtext liefern, nicht den nächsten Dienst
  ausprobieren. „Rohtext“ heißt dabei: keine Wortänderung und nichts aus der
  LLM-Ausgabe, aber die deterministische Nachstufe `TranscriptPolish.repairPunctuation`
  läuft darauf (Satzzeichen/Großschreibung, damit ein Diktat ohne Bereinigung lesbar
  ankommt). Die Längenkorridor-Prüfung ist eine Sicherheitsgrenze.
- Keep-alive: primäres Modell standardmäßig `2h`, Fallbacks `30m`. `-1` bleibt
  optional für dauerhaftes Laden; nur dann darf der periodische Warm-up laufen.
- Erfolg löscht die temporäre WAV-Datei. Jeder Fehler behält sie zur Diagnose.

## Datenschutz und Secrets

- Audio bleibt immer lokal und darf nie an einen Cloud- oder LAN-LLM-Endpunkt
  übertragen werden. Nur Text verlässt optional den Rechner. Das ist keine bloße
  Vereinbarung, sondern erzwungen: `WhisperEndpoint` nimmt ausschließlich eine
  ausdrückliche Loopback-Adresse an und löst `localhost` bewusst nicht per DNS auf.
  Diese Prüfung nicht lockern, auch nicht für einen Whisper-Server im eigenen LAN.
- Die Netzwerk-Brücke (`BridgeServer`, ab 0.9.2) ist die einzige Ausnahme in der
  Gegenrichtung und bleibt reiner **Empfänger**: Sie nimmt Audio von eigenen
  Geräten im Heimnetz an und verarbeitet es auf diesem Mac über den lokalen
  whisper-server. Stille Post sendet weiterhin selbst nie Audio. Die Brücke ist
  standardmäßig aus, verlangt ein Token aus dem Schlüsselbund und weist
  Verbindungen ab, die nicht aus dem eigenen Netz kommen. Diese drei
  Eigenschaften sind nicht verhandelbar; Details in `docs/ios-bridge.md`.
  „Eigenes Netz“ heißt seit 0.9.8: private IPv4-Bereiche, Link-Local, IPv6-ULA
  und eine globale IPv6-Adresse im selben Netzbereich wie eine Adresse dieses
  Macs. Die frühere Fassung nannte nur „privater Adressbereich“ und sperrte damit
  das iPhone aus, sobald es über das globale IPv6-Präfix der FRITZ!Box kam.
- Serielle Serverarbeit braucht zusätzlich eine begrenzte Warteschlange. Die
  Verkettung in `BridgeRouter.serialized` reiht Anfragen zwar sauber
  hintereinander, hält aber pro wartender Task den vollständigen
  `BridgeRequest` samt Audio-Body im Speicher — ohne Kapazitätsgrenze ist das
  eine Speicher- und CPU-Angriffsfläche, die die Größengrenze pro Anfrage nicht
  abdeckt. Die Warteschlange muss eine Obergrenze haben, Überlast mit einem
  klaren Fehler ablehnen (statt unbegrenzt anzunehmen) und angefangene Arbeit
  bei Verbindungsabbruch stornieren.
- API-Schlüssel nur über Umgebungsvariable oder Schlüsselbund beziehen. Nie in
  Quelltext, Konfiguration, Logs, Terminalargumente, Test-Fixtures oder Git schreiben.
- Schlüsselbundzugriff nie in einem SwiftUI-Renderpfad ausführen; nur asynchron oder
  nach expliziter Nutzeraktion. Renderpfade müssen nebenwirkungsfrei bleiben.
- Diagnoseausgaben dürfen weder Schlüssel noch vollständige sensible Diktate
  ausgeben. Testdaten künstlich und nicht persönlich halten.
- Öffentliche Dateien dürfen keine privaten Hosts, IPs, Kontakte oder persönlichen
  absoluten Pfade enthalten. Beispiele mit `$HOME` oder neutralen Platzhaltern.

## Verhalten und bekannte Plattformgrenzen

Bei Audio-, Clipboard-, GUI- oder Plattformänderungen [Verhalten und bekannte Plattformgrenzen](AGENT-REFERENCE.md#verhalten-und-bekannte-plattformgrenzen) lesen.

## Bauen und testen

Vor Build, Installation und Tests [Bauen und testen](AGENT-REFERENCE.md#bauen-und-testen) lesen.

## Änderungskonventionen und Git

- Identifier Englisch, Dokumentation und Kommentare Deutsch. Nicht offensichtlichen
  Code anfängerfreundlich kommentieren; bei Refactor/Rename bestehende Kommentare
  mitnehmen und anpassen.
- Änderungen klein halten und die Kernlogik bevorzugt in `StillePostCore` testbar
  machen. UI-Code soll orchestrieren, nicht Geschäftslogik duplizieren.
- Nur aufgabenbezogene Pfade stagen; fremdes WIP unangetastet lassen. Kein
  `git add .`, kein `git add -A`, kein destruktiver Reset oder Clean.
- Nach vollständig umgesetzter und verifizierter Verhaltensänderung die Version nach
  Repo-Konvention anheben, committen und ausschließlich zum privaten kanonischen
  Fleet-Remote aus den globalen Regeln pushen. Eine reine Reorganisation von
  AGENTS/Doku erfordert keinen Produktversions-Bump.
- GitHub-/`origin`-Push, Tag, notarisiertes Release oder Veröffentlichung nur auf
  ausdrücklichen konkreten Auftrag. Vor öffentlicher Ausgabe auf private Hosts,
  Kontakte, interne Formulierungen und Pfade prüfen.

## Aktive nächste Arbeit

Die kanonische Liste liegt in [backlog.md](backlog.md). Derzeit relevant:
mehrtägiger Realbetrieb auf beiden Macs, danach evidenzbasierte
Modellentscheidung und Qualitäts-/Latenzbenchmark; Live-Text und Silero-VAD nur
optional. Erledigte Release-, README-, Lizenz-, Settings-, Hotkey-Recorder- und
Login-Item-Arbeit nicht wieder als Startkontext führen.

## Progressive Details

Vor Änderungen gezielt lesen statt alles in den Startkontext zu kopieren:

- `README.md`: Nutzung und Installation.
- Build-/Release-Skripte: tatsächliche Signatur- und Paketlogik.
- Tests neben der betroffenen Kernkomponente: ausführbarer Vertrag.
- `CHANGELOG.md`/Release Notes: historische Entscheidungen und erledigte Arbeit.
- Backlog/Task-Dateien: aktive Planung und Akzeptanzkriterien.

Es gibt keine verschachtelte `AGENTS.md`. Ignorierte Build-, Xcode- und lokale
Artefakte sind nicht autoritativ und dürfen keine versteckten Projektregeln tragen.

## Verzeichnisstruktur

- [CLAUDE.md](CLAUDE.md) — Symlink auf diesen Kanon.
- [README.md](README.md) und [README.de.md](README.de.md) — Nutzung, Installation
  und Architektur in beiden Sprachen.
- [backlog.md](backlog.md) — einzige aktive Projektliste.
- [CHANGELOG.md](CHANGELOG.md) — Produktgeschichte je Version; ab 0.8.2 mit dem
  Versions-Bump fortzuschreiben.
- [docs/ios-bridge.md](docs/ios-bridge.md) — Diktat vom iPhone über das Heimnetz:
  getroffene Entscheidungen, Aufbau der Brücke, Kurzbefehl-Anleitung, Messwerte.
