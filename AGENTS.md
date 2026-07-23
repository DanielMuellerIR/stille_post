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
- `scripts/build-app.sh`: App-Bundle; `scripts/e2e-test.sh`: lokaler End-to-End-
  Lauf; `VERSION`: Produktversion.

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
- Primärer Endpunkt: direkter Streaming-Request. Bei Verbindungsfehler genau ein
  sofortiger Versuch in einer frischen Sitzung, danach die geordnete Fallback-Kette.
  Fallback-Probes bleiben non-streaming; keine parallelen oder gehedgten Requests.
- Fallback-Semantik: Netzwerk-/Dienstfehler → nächster Endpunkt. Plausibilitätsfehler
  des bereinigten Textes → unveränderten Rohtext liefern, nicht den nächsten Dienst
  ausprobieren. Die Längenkorridor-Prüfung ist eine Sicherheitsgrenze.
- Keep-alive: primäres Modell standardmäßig `2h`, Fallbacks `30m`. `-1` bleibt
  optional für dauerhaftes Laden; nur dann darf der periodische Warm-up laufen.
- Erfolg löscht die temporäre WAV-Datei. Jeder Fehler behält sie zur Diagnose.

## Datenschutz und Secrets

- Audio bleibt immer lokal und darf nie an einen Cloud- oder LAN-LLM-Endpunkt
  übertragen werden. Nur Text verlässt optional den Rechner.
- API-Schlüssel nur über Umgebungsvariable oder Schlüsselbund beziehen. Nie in
  Quelltext, Konfiguration, Logs, Terminalargumente, Test-Fixtures oder Git schreiben.
- Schlüsselbundzugriff nie in einem SwiftUI-Renderpfad ausführen; nur asynchron oder
  nach expliziter Nutzeraktion. Renderpfade müssen nebenwirkungsfrei bleiben.
- Diagnoseausgaben dürfen weder Schlüssel noch vollständige sensible Diktate
  ausgeben. Testdaten künstlich und nicht persönlich halten.
- Öffentliche Dateien dürfen keine privaten Hosts, IPs, Kontakte oder persönlichen
  absoluten Pfade enthalten. Beispiele mit `$HOME` oder neutralen Platzhaltern.

## Verhalten und bekannte Plattformgrenzen

- Nach erfolgreicher Verarbeitung wird der Text über die Zwischenablage eingefügt.
  Synthetisches `Cmd+V` passiert eine Screen-Sharing-Grenze nicht zuverlässig. Ist
  der Viewer die Front-App, nur kopieren und zum manuellen Einfügen auffordern; die
  vorherige Zwischenablage in diesem Fall nicht automatisch zurückschreiben.
- Whisper `language=auto` kann kurze deutsche Segmente übersetzen. Für verlässliches
  deutsches Diktat eine feste Sprache anbieten/empfehlen; der E2E-Test verwendet eine
  feste Sprache.
- TCC-Freigaben hängen an Signatur und Bundle-Identität. Release-/Testsignaturen nicht
  beiläufig wechseln. Eine Developer-ID-Signatur stabilisiert Freigaben.
- Notarisierte Builds benötigen das Audio-Entitlement. Alle eingebetteten Binaries,
  einschließlich CLI, einzeln und von innen nach außen signieren.
- Notarisierungs-/Signaturarbeit kann unter SSH am gesperrten Login-Schlüsselbund
  scheitern; dafür ist eine angemeldete GUI-Sitzung erforderlich. Keine Secrets in
  Argumente schreiben.
- Headless UI-Einstiege für Tests erhalten:
  `STILLEPOST_OPEN_SETTINGS=<tab>` und
  `STILLEPOST_OPEN_HISTORY=1` sowie `STILLEPOST_OVERLAY_PREVIEW=<state>`.
  Lokalisierte Screenshots isolieren Sprache und Nutzerdaten mit
  `STILLEPOST_LANGUAGE=<de|en>` und `STILLEPOST_APP_SUPPORT=<wegwerf-ordner>`;
  `STILLEPOST_ALLOW_MULTIPLE=1` hält dabei eine installierte Alltagsinstanz
  unangetastet.

## Bauen und testen

Mindestens die zur Änderung passende Stufe ausführen; Testanzahlen nie in Doku
festschreiben, weil sie veralten.

```bash
swift build
swift test
bash scripts/build-app.sh
```

`scripts/e2e-test.sh` benötigt ein installiertes Whisper-Modell und den lokalen
LLM-Dienst. Es ist für Änderungen an Audio→Text→Cleanup, Modellen, Prompting,
Fallbacks oder Konfiguration zusätzlich auszuführen. GUI-/Hotkey-Änderungen brauchen
einen echten App-Bundle-Smoke-Test; Signatur/Notarisierung braucht die vorhandenen
Build-Prüfungen und einen Start des resultierenden Bundles.

Änderungsspezifische Evals:

- Streaming/Zusammenfügen: mehrere Segmente ergeben genau einen Cleanup-Aufruf in
  richtiger Reihenfolge.
- Fallback: Netzwerkfehler wechselt den Endpunkt; Plausibilitätsfehler liefert Rohtext.
- Datenschutz: kein Request enthält Audiobytes; Logs und Fehler enthalten keinen Key.
- Dateien: WAV nach Erfolg weg, nach jedem Fehler vorhanden.
- Clipboard/Screen Sharing: Viewer-Fall kopiert ohne automatisches Paste und ohne
  Wiederherstellung des alten Clipboard-Inhalts.
- Konfiguration: Warm-up und Chat teilen `num_ctx`; `think` bleibt aus.

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
