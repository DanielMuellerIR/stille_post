# Aktiver Backlog

## iPhone-Diktat über das Heimnetz (Stufe 0 gebaut in 0.9.2)

Entscheidungen, Aufbau, Kurzbefehl-Anleitung und Messwerte stehen in
[docs/ios-bridge.md](docs/ios-bridge.md). Kurz: Die Brücke im Mac nimmt Audio oder
Rohtext von eigenen Geräten an, das iPhone bedient sie über einen Kurzbefehl am
Action-Button und fügt den Text aus der Zwischenablage ein. Keine
Tastatur-Erweiterung, kein Fernzugriff — beides bewusst verworfen.

Am 2026-07-29 am iPhone verifiziert: Kurzbefehl an der Aktionstaste, zwei
Diktate bis in die Zwischenablage. Beide Rückfragen sind geklärt — die
iOS-Abfrage fürs lokale Netzwerk kommt beim ersten Lauf, und *Audio aufnehmen*
landet nur dann im Anfragetext, wenn dieser ausdrücklich auf „Datei" gestellt
wird. Die beiden Stolpersteine beim Einrichten (`Bearer` gehört mit in den
Header-Wert; Anfragetext von `JSON` auf `Datei` umstellen) stehen jetzt samt
Schlüsselbund-Hinweis in [docs/ios-bridge.md](docs/ios-bridge.md).

Offen:

- Die macOS-Firewall-Freigabe für eingehende Verbindungen ist ungeprüft (auf diesem
  Mac ist die Firewall nicht aktiv). Auf einem Mac mit aktiver Firewall muss die
  einmalige Freigabe erscheinen und danach bestehen bleiben.
- Verhalten bei Ruhezustand des Macs ist nicht ausgemessen: Ob „Für Netzwerkzugriff
  aufwachen" reicht, damit ein Diktat den Mac weckt, oder ob der Kurzbefehl dann
  einfach scheitert.

Stufe 1 (erst wenn Stufe 0 im Alltag trägt): eigene kleine iPhone-App in diesem
Repo. Sie bringt drei Dinge, die ein Kurzbefehl nicht kann — TLS mit gemerktem
Zertifikats-Fingerabdruck (heute läuft die Verbindung im Klartext durchs WLAN),
eine Kopplung per QR-Code statt Token-Einfügen, und später Whisper lokal auf dem
iPhone für unterwegs. Auf dem iPhone 16 Pro Max ist `large-v3-turbo` über WhisperKit
realistisch (quantisiert 550–630 MB, etwa fünffache Echtzeit); Parakeet aus dem
gleichen SDK wäre der kleinere Kandidat und passt zum Benchmark-Punkt weiter unten.
Für App-Erweiterungen bräuchte das ein Xcode-Projekt — `*.xcodeproj` ist derzeit
ignoriert, das wäre dann anzupassen.

## Whisper-Modell selbst beschaffen (gebaut in 0.8.0, READMEs offen)

Ziel: Stille Post soll auf einem nackten Mac benutzbar sein, ohne dass man sich
selbst um Whisper kümmert. Bis 0.8.0 lief die App nur, weil vorher OpenWhispr das
Modell installiert hatte — das war kein Zustand für andere Nutzer.

Festlegung (0.8.0): **Nur `large-v3-turbo` anbieten, keine kleineren Modelle.** So
groß ist Turbo nicht (~1,6 GB), und schlechtere Qualität will niemand. Die App darf
diese Entscheidung vorwegnehmen, statt sie dem Nutzer aufzuhalsen.

Optional als einzige Wahl daneben: **volles `large-v3`**. Auszuprobieren bleibt,
ob es Fremdwörter und Fachbegriffe besser trifft. Wenn es sich als
besser erweist, kann es Standard werden — die Repo-Regel verlangt dafür Qualitäts-
UND Latenzmessung.

Der Halluzinations-Prüfstein für so eine Messung (billig, kein Mikrofon nötig):

```bash
python3 - <<'PY'
import wave, struct
with wave.open("/tmp/silence.wav","w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(struct.pack("<%dh" % (16000*5), *([0]*(16000*5))))
PY
curl -s http://127.0.0.1:8181/inference -F file=@/tmp/silence.wav \
     -F response_format=json -F temperature=0 -F language=de
# liefert auf large-v3-turbo: {"text":" Vielen Dank."}
```

Erwartungsdämpfer: Die Stille-Halluzination ist bei allen Whisper-Modellen
dokumentiert und steckt in den Trainingsdaten (YouTube-Untertitel), nicht in der
Modellgröße. `large-v3` würde sie höchstens seltener machen, nicht beheben — die
App fängt sie seit 0.7.2 ohnehin vorher ab (`minSpeechSec`). Eine Konfidenz-Schwelle
hilft übrigens nicht: Auf reiner Stille meldet Whisper `no_speech_prob: 2.95e-08`
und `avg_logprob: -0.25`, ist sich also absolut sicher.

Stand nach 0.8.0 — die Beschaffung selbst ist gebaut:

- `stillepost-cli install-model [large-v3-turbo|large-v3]` lädt das Modell nach
  `whisper.modelPath`, mit Fortschritt, Wiederaufnahme und Größenprüfung.
  Wiederholbar (schon da -> Exit 0), stdout enthält nur den Pfad.
- Die App fragt beim Start, wenn das Modell fehlt oder nur geliehen ist, und lädt
  es mit Fortschrittsbalken. Bewusst als Frage: 1,6 GB zieht man niemandem ungefragt.
- `doctor` unterscheidet jetzt eigene Kopie / geliehener Verweis / fehlt und nennt
  den passenden Befehl.
- `scripts/install-model.sh` bleibt als skriptbarer Weg und kann dasselbe.
- Der Entwicklungsrechner hat seit 2026-07-15 eine eigene Kopie; der OpenWhispr-Cache ist weg.

READMEs sind in beiden Sprachen nachgezogen: Modellbeschaffung, die zwei angebotenen
Modelle, und `brew install whisper-cpp` klar als einzige verbleibende Handarbeit
benannt (Entscheidung 2026-07-15: dokumentieren, nicht abdecken — die App
greift nicht in fremde Paketverwaltungen ein und bettet nichts ein).

Offen:

- Der Modell-Download der App ist noch nicht per GUI-Smoke-Test gesehen worden;
  Kern und CLI sind gegen das echte Hugging Face verifiziert.
- **Die CLI liegt nicht im PATH** — sie steckt im App-Bundle unter
  `/Applications/StillePost.app/Contents/MacOS/stillepost-cli`. Die READMEs erklären
  jetzt den Symlink nach `/usr/local/bin`, aber `build-app.sh --install` könnte das
  auch selbst anbieten. Offene Entscheidung, weil es sudo braucht.

## Warm-on-Intent statt Dauer-Pin (beschlossen 2026-07-15, vollständig umgesetzt 2026-07-28)

Ziel: Das Bereinigungsmodell soll nicht mehr dauerhaft im Speicher hängen, sondern
nach einem Timeout entladen werden. Die Wartezeit wird dadurch nicht spürbar, weil
das Modell bereits beim Diktat-Start vorgeladen wird — es lädt, während man spricht.

Beschlossene Eckwerte (festgelegt 2026-07-15, nicht neu verhandeln):

- Stille-Post-Default für `keep_alive`: **2h** am Primär-Endpoint, **30m** an den
  Fallbacks (heutiges Fallback-Verhalten).
- Cleanup-Modell: Der **Default ist `gemma4:e4b-it-qat`** (seit 2026-07-23
  evidenzbasiert, siehe `Config.swift` und `docs/cleanup-model-benchmark.md`). Ein
  diszipliniertes kleines Modell putzt hier treuer als die großen; ~6 GB, passt auf die
  meisten Macs. (Ersetzt die frühere Annahme „Default `qwen3.5:9b`, Referenz `gemma4:26b`".)
- Number One: Chat, eBook und Repo-RAG einheitlich auf `qwen3.6:35b`, Timeout 20 min.
- Log-Verify (`llm.py`) bleibt auf `gemma4:26b`.

### Teil A — Stille Post: keep_alive konfigurierbar — ERLEDIGT in 0.7.0

Umgesetzt und gegen ein echtes Ollama verifiziert. Der ausstehende Blick aufs
Dropdown im Bereinigungs-Tab ist am 2026-07-16 erfolgt (manuell verifiziert, an 0.8.0): ist da
und lesbar. Teil A ist damit vollständig abgeschlossen.

Bewusste Grenze (gilt weiter): Echte Ollama-*Daemon*-Konfiguration
(`OLLAMA_HOST=0.0.0.0`, globaler `OLLAMA_KEEP_ALIVE`, `ollama pull`) kann die App für
einen entfernten Host nicht setzen. Das gehört in die README-Anleitung (Teil C) und
in `doctor`-Warnungen, nicht in einen App-Eingriff in fremde Daemons.

### Teil B — Gegenstück auf der Server-Seite (außerhalb dieses Repos) — ERLEDIGT 2026-07-28

Die zugehörigen Anpassungen der privaten Host-Umgebung (Chat-Defaults,
`keep_alive`-Werte, Modell-Preload samt Aufwärm-Knopf in den Oberflächen) sind
am 2026-07-28 umgesetzt und am echten Server verifiziert worden. Die Details
werden weiterhin außerhalb dieses Repos geführt.

### Teil C — README (beide Sprachen)

ERLEDIGT. Die vorhandene Sektion „Bereinigung auf einem stärkeren Rechner" trägt
jetzt die Schritt-für-Schritt-Anleitung für beide Seiten, die keep_alive-Erklärung
und den Hinweis auf die Hotkey-Aufnahme — in beiden Sprachen.

### Beobachtung, die zu Teil B gehörte — aufgeklärt 2026-07-28

Am 2026-07-15 gingen von einem Client-Mac aus rund 44 Anfragen pro Minute an das
Ollama des starken Macs, jeweils `POST /api/generate` gefolgt von `GET /api/tags`.
Bei der Umsetzung von Teil B haben sich beide damaligen Schlussfolgerungen als
falsch erwiesen:

- Der Burst kam nicht von wiederholten `doctor`-Läufen, sondern von der eigenen
  LLM-Delegation des Client-Macs (deren Agent-Werkzeuge fragen `/api/tags` zur
  Modellwahl ab). (Ersetzt die frühere Aussage, `/api/tags` rufe ausschließlich
  `stillepost-cli doctor` auf und die Quelle sei ungeklärt.)
- Anfragen ohne `keep_alive` verkürzen eine bestehende Warmhaltung NICHT —
  Ollama behält die bereits gesetzte Ladefrist; nur eine Anfrage, die selbst ein
  `keep_alive` mitschickt, ändert sie. Die Sorge, ein solcher Burst mache eine
  eingestellte 2-Stunden-Frist wirkungslos, war damit unbegründet. (Ersetzt die
  frühere Aussage, solche Anfragen setzten das Modell auf Ollamas 5-Minuten-Default
  zurück.)

Zu prüfen bleibt hier nichts mehr; der Punkt bleibt als korrigierte Historie stehen.

## GUI-Tests dieser App (Befund 2026-07-15)

Warum visuelle Smoke-Tests hier zweimal gescheitert sind — die bisherige Erklärung
war falsch und hat die Suche in die falsche Richtung geschickt:

- **Nicht** der Spotlight-Index. Der ist aktiv, und `mdfind` findet
  `/Applications/StillePost.app` sofort.
- Die Ursache ist `LSUIElement = 1` im Info.plist. Stille Post ist eine
  Menüleisten-App ohne Dock-Symbol; die Computersteuerung des Assistenten führt
  solche Apps gar nicht erst in ihrer Liste steuerbarer Anwendungen. Weder der
  Anzeigename „StillePost" noch die Bundle-ID werden gefunden.
- `LSUIElement` ist kein Fehler, sondern Absicht (Menüleisten-App). Es soll bleiben.

Auch der dokumentierte Ausweg „`@StillePost` in den Prompt tippen" hilft nicht —
2026-07-16 probiert, die App bleibt unauflösbar. Für die *Computersteuerung* gibt es
damit keinen bekannten Weg.

**Ein Agent kann die Oberfläche trotzdem prüfen — ohne Test-Hook** (2026-07-16 am
Modell-Dialog durchgeführt). Die Computersteuerung ist nicht der einzige Weg:

- Starten mit `open` ist der Umweg; das Binary direkt starten nimmt Umgebungs-
  variablen an: `STILLEPOST_CONFIG=<wegwerf.json> .../Contents/MacOS/StillePost &`.
- `screencapture -x <datei.png>` per Bash nimmt den Bildschirm auf — die
  Bildschirmaufnahme-Freigabe des Terminals genügt, LSUIElement stört dabei nicht.
  Ein zentrierter Ausschnitt (`sips -c`) zeigt modale Dialoge lesbar, ohne den
  restlichen Bildschirminhalt auszuwerten.
- Der Einzelinstanz-Schutz bleibt: Die laufende App muss vorher weichen
  (`pkill -x StillePost`) und danach wieder gestartet werden.

Damit ist der Test-Hook `STILLEPOST_DOCK_ICON=1` nicht nötig, um Dialoge zu prüfen.
Er bliebe nur interessant, wenn ein Agent wirklich *klicken* statt nur *sehen* muss;
gebaut und beschlossen ist er weiterhin nicht.

Erledigt am 2026-07-16 auf diesem Weg (manuell am Schirm verifiziert, an 0.8.0):

- keep_alive-Dropdown: da und lesbar.
- Login-Item-Schalter: da, anklickbar, hält beim Einschalten. Systemseitig belegt
  über `sfltool dumpbtm` (ohne root lesbar): `io.github.danielmuellerir.stillepost`,
  URL `/Applications/StillePost.app/`, `Disposition: [enabled, allowed, notified]`.
- Modell-Dialog: beide Zustände am Bildschirm geprüft (2026-07-16, Build 0.8.1).
  Über eine wegwerfbare `STILLEPOST_CONFIG` ausgelöst, ohne das echte Modell
  anzufassen; „Laden“ wurde bewusst nie geklickt. „Whisper-Modell fehlt“ und
  „Whisper-Modell ist nur geliehen“ erscheinen mit korrektem Text, Zielpfad und der
  Wahl Später/Laden. Der geliehene Fall wurde mit einem Verweis auf einen gar nicht
  mehr existierenden Cache ausgelöst und trotzdem als „geliehen“ erkannt, nicht als
  „fehlt“ — der `lstat`-Vertrag hält auch am echten Pfad.

Weiterhin offen:

- Der echte Ab-/Anmeldezyklus für das Login-Item (Entscheidung: im Alltag,
  die Registrierung genügt als Beleg).

## Beim Dialog-Test aufgefallen (2026-07-16, unentschieden)

- **Größen stehen in MB, auch jenseits von 1 GB.** Der Dialog sagt „1549 MB“, die
  Commit-Historie und die READMEs sprechen von „1,6 GB“. Beides ist richtig (1549 MiB
  = 1,62 GB), aber der Nutzer denkt bei vierstelligen MB in GB. Eine Anzeige, die ab
  1024 MB auf GB wechselt, wäre freundlicher — wäre aber eine Verhaltensänderung samt
  Versions-Bump und ist deshalb nicht beiläufig gemacht worden.

## Icon-Nachzieharbeit (offen seit 0.8.2, 2026-07-16)

- **Der Modell-Dialog ist mit dem neuen Icon nicht am Bildschirm nachgeprüft.**
  Geprüft ist die Ebene darunter: LaunchServices liefert für `/Applications/
  StillePost.app` unser Icon über die volle Größenstaffel aus, was Finder und
  Anmeldeobjekte bedienen. Der Dialog ist ein `NSAlert` und zieht sein Bild aus
  demselben Bundle-Icon, sollte also stimmen — beobachtet wurde es aber nicht, und
  genau dort war der Platzhalter ursprünglich aufgefallen. Der Dialog erscheint nur
  bei fehlendem Modell; wie er ohne Test-Hook zu provozieren ist, steht oben unter
  „GUI-Tests dieser App".
- **`scripts/build-icon.sh` steht in keiner der beiden READMEs.** Dort sind
  `build-app.sh`, `install-model.sh` und `e2e-test.sh` aufgeführt. Bewusst nicht
  beiläufig ergänzt, weil die Icon-Änderung sonst in die READMEs ausgefranst wäre.
  Relevant nur für den, der die Zeichnung ändert — das `.icns` liegt fertig im Repo.

## Offen aus dem Code-Review vom 2026-08-06

Der Report ist abgearbeitet: vierzehn der sechzehn Funde sind in 0.9.6 behoben,
einer war ein Fehlbefund (die Retry-Regel in `AGENTS.md` war zu eng formuliert,
nicht der Code falsch). Hier steht, was offen blieb — ein Fund, der zu groß für
einen chirurgischen Fix ist, und die Reste zweier Fixes.

- **Abnahme des Brücken-Lifecycle am App-Bundle.** Der Start läuft jetzt über
  einen Callback außerhalb des Hauptthreads. Abschalten storniert aktive Sessions;
  eine neue Instanz wartet auf die bestätigte Freigabe des alten Listeners.
  Kern-Gegenproben für Start, Stop, Neustart und TCP-Reset sind bestanden.
  Die Abnahme an einem frisch notarisierten Bundle und über das echte Heimnetz
  bleibt offen.
- **Abbruch von Transkription und Bereinigung.** Router-Tasks werden bereits
  storniert; Decoder und Whisper-Selbststart prüfen jetzt zusätzlich den Abbruch.
  Eine stornierte Bereinigung startet weder eine zweite Probe noch Retry/Fallback.
  Kern-Gegenproben sind bestanden; der reale Verbindungsabbruch während eines
  Diktats über das App-Bundle bleibt zu prüfen.
- **Sperrliste der Worttreue-Prüfung kennt nur Deutsch und Englisch.**
  `CleanupService.meaningCriticalWords` deckt seit 0.9.6 beide Sprachen ab.
  `whisper.language` steht aber standardmäßig auf `auto`: Bei einem
  französischen, spanischen oder italienischen Diktat kann eine verschluckte
  Verneinung weiterhin als gewöhnliche Füllwort-Löschung durchgehen. Sauberer
  als jede Sprache einzeln nachzupflegen wäre, Löschungen nur über eine
  sprachabhängige Positivliste sicherer Füllwörter zu erlauben. Auch DE/EN ist
  betroffen: Die Gegenprobe mit „ich überweise hundert euro“ → „Ich überweise
  Euro.“ sowie „I approve this tomorrow“ → „I approve this.“ schlägt fehl.
  Offen ist die Entscheidung, ob mehrdeutige Füllwörter zugunsten der Worttreue
  erhalten bleiben sollen.

## Offen aus dem Code-Review vom 2026-08-20

Der Report (17 Funde) ist abgearbeitet: 15 Funde sind behoben, zwei bleiben
liegen, weil sie mehr als einen chirurgischen Eingriff brauchen.

- **TCP-Halbschluss: Kern korrigiert, Netzabnahme offen.** Ein vollständig
  übertragener Request wird trotz Empfangs-EOF beantwortet. EOF beendet nur
  die Senderichtung des Clients; Reset/Fehler, Abschalten und fehlgeschlagenes
  Senden stornieren Arbeit. Die Gegenproben unterscheiden HTTP 200 nach
  `shutdown(SHUT_WR)` und echte Cancellation nach TCP-Reset. Der Transport
  behält nach dem Senden seine begrenzte Abholfrist. Eine Gegenprobe über das
  echte Heimnetz am aktuellen notarisierten App-Bundle fehlt noch.
- **Der Modell-Download beweist nur die Dateigröße, nicht den Inhalt.** Die
  Quelle zeigt auf `…/resolve/main/…`, also auf einen veränderlichen Stand, und
  die Abschlussprüfung vergleicht ausschließlich die Bytezahl. Seit 2026-08-20
  prüft die Wiederaufnahme immerhin `Content-Range` streng (Startversatz und
  Gesamtgröße müssen zur Anfrage passen), und eine zu große Teildatei wird
  verworfen. Was fehlt: die Quelle auf eine Revision festnageln und den
  bekannten SHA-256 beider Modelle vor dem Verschieben prüfen. Dafür müssen die
  Prüfsummen einmal an echten Downloads (1,6 GB und 3,1 GB) ermittelt und im
  Katalog hinterlegt werden; danach ist ein Modellwechsel bei Hugging Face eine
  bewusste Aktualisierung statt einer stillen Änderung.

## Weitere offene Arbeit

- GitHub-Push-Stopp aufgehoben (2026-08-10). Die Bedingung „bis die App
  sinnvoll nutzbar ist" ist erfüllt: Lokales Diktat läuft, und das Diktat vom
  iPhone ist über die vollständige Kette einmal am Gerät bestätigt.
- Sparkle: VOLLSTÄNDIG ERLEDIGT. Die Erstveröffentlichung war am 2026-08-10
  geprüft (Pages liefert den Feed, Team-ID als Actions-Variable, privater
  Schlüssel als Actions-Secret, Appcast-Workflow bei allen Releases erfolgreich).
  Die zuletzt offene Probe am Gerät — ein echter Updatelauf von einer älteren
  Fassung — ist am 2026-08-15 bestätigt.
- Mehrtägigen Realbetrieb auf beiden vorgesehenen Macs durchführen und Befunde mit
  Datum, Build und Konfiguration notieren.
- Cleanup-Modell-Benchmark: ERLEDIGT (2026-07-23). Evidenzbasierter Default ist jetzt
  `gemma4:e4b-it-qat` (öffentlich pullbar, ~6 GB); ein diszipliniertes kleines Modell
  schlägt die großen. Methodik, 12-Modelle-Vergleich und READMEs in
  `docs/cleanup-model-benchmark.md`.
- Login-Item: gebaut und verifiziert in 0.8.1. Offen bleibt nur das Deaktivieren im
  Alltag und der echte Ab-/Anmeldezyklus.
- Optional später: Live-Text-Anzeige und Silero-VAD evaluieren.
- FluidAudio/Parakeet-Benchmark (Idee 2026-07-24): FluidAudio
  (https://github.com/FluidInference/FluidAudio) ist ein Swift-SDK für lokale
  Audio-KI auf der Apple Neural Engine — ASR mit Parakeet TDT v3 (0,6B, Deutsch,
  sehr schnell, liefert Interpunktion/Großschreibung nativ und hat Whispers
  Übersetzungsproblem bei kurzen Segmenten nicht), dazu Silero-VAD. Vor einem
  Engine-Wechsel gilt die Repo-Regel: reproduzierbarer Qualitäts- UND
  Latenzvergleich gegen `large-v3-turbo` mit echten deutschen Diktaten.
  Referenz-Gegenprobe: VoiceInk (GPL-3) baut auf denselben Bausteinen
  (whisper.cpp + optional Parakeet via FluidAudio) — architektonisch kein
  Vorsprung gegenüber Stille Post, aber Ideenquelle (z. B. app-abhängige Modi).
- Keine CI für die Testsuite (Befund CodeQA 2026-08-19). Der einzige Workflow
  (`.github/workflows/publish-appcast.yml`, `macos-15`) läuft erst beim
  Veröffentlichen eines Releases; er prüft dort immerhin Developer-ID und
  Notarisierung über `scripts/verify-release.sh`. `swift test` und die
  Shell-Tests (`scripts/test-release-publication.sh`) laufen dagegen nur, wenn
  jemand sie von Hand startet. Ein Push mit roter Suite fällt damit nirgends
  auf. Zu entscheiden ist vor allem die Kostenfrage: ein `macos`-Runner je Push
  ist nicht umsonst, ein Lauf nur auf `main` oder nur vor einem Release wäre die
  sparsame Variante.
- `release.sh` prüft nicht, ob der Arbeitsbaum sauber ist (Befund CodeQA
  2026-08-19). Das DMG entsteht aus dem Arbeitsbaum, nicht aus dem Commit —
  ein Release mit uncommitteten Änderungen trägt dann einen Tag, zu dem der
  ausgelieferte Build nicht passt. Bisher nie passiert; eine Vorabprüfung
  neben den bereits vorhandenen (Artefakt existiert schon, Team-ID, Notary)
  wäre die naheliegende Stelle. Offen bleibt, ob die Prüfung hart abbricht oder
  sich für Zwischenstände übergehen lässt.
- Eingabegerät-Wechsel während der Aufnahme (Befund CodeQA 2026-08-19, ungeprüft
  an echter Hardware): `AudioRecorder` hört nicht auf
  `AVAudioEngineConfigurationChange`. Wird das Mikrofon mitten im Diktat abgezogen
  oder wechselt macOS das Standardgerät, hört der Tap vermutlich still auf zu
  liefern — die Aufnahme läuft weiter, und Whisper bekommt am Ende nur den Teil
  bis zum Wechsel. Zuerst am Gerät reproduzieren (USB-Mikrofon abziehen, dann
  Bluetooth-Headset trennen), erst danach über die Behandlung entscheiden:
  Aufnahme mit klarer Meldung beenden ist ehrlicher als still weiterzulaufen.
- Wörterbuch-Pflege: Editor mit einem Begriff pro Zeile im Bereinigungs-Tab
  vorbereitet und kompiliert. Sichtprüfung in DE/EN sowie Bearbeiten, Speichern,
  erneutes Öffnen und Abbrechen am aktuellen notarisierten Bundle sind offen.
  Vorbelegung siehe `Config.Cleanup.defaultDictionary` (seit 0.9.0).

Erledigte Release-, README-, Lizenz-, GitHub- und Settings-Arbeit gehört in
Changelog/Release Notes, nicht zurück in diesen Backlog.
