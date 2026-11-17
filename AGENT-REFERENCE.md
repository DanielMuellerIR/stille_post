# Technische Arbeitsreferenz

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
- **Der `.build`-Pfad in `StillePost` und `stillepost-cli` bleibt bewusst stehen.**
  SwiftPM kompiliert in den Zugriff auf `Bundle.module` den Build-Zeit-Pfad des
  Ressourcen-Bundles als Zeichenkette ein. Das ist kein Debug-Symbol, das
  `strip -S` in `scripts/build-app.sh` erwischt es deshalb nicht. Folgenlos: Das
  Bundle liegt in `Contents/Resources` und wird von dort gefunden, der Pfad ist
  ein nie erreichter Rückfall. Wegzubekommen wäre er nur, indem `swift build` mit
  `--scratch-path` außerhalb des Repos baut — das kostet einen zweiten
  Build-Cache. Das wurde am 2026-08-04 bewusst abgelehnt: für Kosmetik lohnt
  der Aufwand nicht. Nicht „reparieren“; der Fund ist als bekannt und
  unkritisch vermerkt und soll auch von Code-Reviews nicht erneut gemeldet
  werden.
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
- Netzwerk-Brücke: falsches oder fehlendes Token wird auf jeder Route abgewiesen;
  eine Anfrage über der Größengrenze schon anhand von `Content-Length`; ein Diktat
  ergibt genau einen Bereinigungsaufruf; mehr gleichzeitige Anfragen als die
  Warteschlangengrenze werden abgelehnt statt gepuffert. Zusätzlich einmal echtes
  Audio über `.local` durchschicken — das prüft die Umwandlung von AAC nach
  16 kHz mono mit.
