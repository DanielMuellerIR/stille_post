# Aktiver Backlog

## Whisper-Modell selbst beschaffen (gebaut in 0.8.0, READMEs offen)

Ziel: Stille Post soll auf einem nackten Mac benutzbar sein, ohne dass man sich
selbst um Whisper kümmert. Bis 0.8.0 lief die App nur, weil vorher OpenWhispr das
Modell installiert hatte — das war kein Zustand für andere Nutzer.

Daniels Festlegung: **Nur `large-v3-turbo` anbieten, keine kleineren Modelle.** So
groß ist Turbo nicht (~1,6 GB), und schlechtere Qualität will niemand. Die App darf
diese Entscheidung vorwegnehmen, statt sie dem Nutzer aufzuhalsen.

Optional als einzige Wahl daneben: **volles `large-v3`**. Daniel will es
ausprobieren, ob es Fremdwörter und Fachbegriffe besser trifft. Wenn es sich als
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
- Der M3 hat seit 2026-07-15 eine eigene Kopie; der OpenWhispr-Cache ist weg.

READMEs sind in beiden Sprachen nachgezogen: Modellbeschaffung, die zwei angebotenen
Modelle, und `brew install whisper-cpp` klar als einzige verbleibende Handarbeit
benannt (Daniels Entscheidung 2026-07-15: dokumentieren, nicht abdecken — die App
greift nicht in fremde Paketverwaltungen ein und bettet nichts ein).

Offen:

- Der Modell-Download der App ist noch nicht per GUI-Smoke-Test gesehen worden;
  Kern und CLI sind gegen das echte Hugging Face verifiziert.
- **Die CLI liegt nicht im PATH** — sie steckt im App-Bundle unter
  `/Applications/StillePost.app/Contents/MacOS/stillepost-cli`. Die READMEs erklären
  jetzt den Symlink nach `/usr/local/bin`, aber `build-app.sh --install` könnte das
  auch selbst anbieten. Offene Entscheidung, weil es sudo braucht.

## „Vielen Dank"-Artefaktfilter (zurückgestellt 2026-07-15)

Die Ursache der „Vielen Dank"-Halluzinationen ist in 0.7.2 an der Quelle behoben
(`minSpeechSec`: ein Tastenklick beim Stoppen der Aufnahme setzte das Segment auf
„hat Sprache", worauf Whisper reine Stille zu sehen bekam und Floskeln erfand).

Offen bleibt nur der Artefaktfilter: `WhisperClient.cleanWhisperArtifacts` kennt
`"vielen dank fürs zuschauen"`, aber nicht das nackte `"vielen dank"` — und
vergleicht auf exakte Gleichheit der GANZEN Ausgabe. Da die Floskel immer an echtem
Text klebte, griff er nie.

Daniels Entscheidung: **zurückgestellt.** Erst mehrere Tage Realbetrieb; taucht die
Floskel nicht mehr auf, ersatzlos streichen statt bauen. Der Filter wäre ohnehin
heikel, weil „Vielen Dank." am Ende eines Diktats echt gemeint sein kann — er würde
also genau den Fehler einführen, den wir gerade beseitigt haben.

## Warm-on-Intent statt Dauer-Pin (beschlossen 2026-07-15, noch nicht umgesetzt)

Ziel: Das Bereinigungsmodell soll nicht mehr dauerhaft im Speicher hängen, sondern
nach einem Timeout entladen werden. Die Wartezeit wird dadurch nicht spürbar, weil
das Modell bereits beim Diktat-Start vorgeladen wird — es lädt, während man spricht.

Beschlossene Eckwerte (Entscheidungen von Daniel, nicht neu verhandeln):

- Stille-Post-Default für `keep_alive`: **2h** am Primär-Endpoint, **30m** an den
  Fallbacks (heutiges Fallback-Verhalten).
- Cleanup-Modell: Der **Default bleibt `qwen3.5:9b`** (so steht es im Code, siehe
  `Config.swift`). Daniel fährt auf seinem Setup `gemma4:26b` — das ist eine
  Konfigurationsentscheidung, keine Default-Änderung: ~18 GB RAM nur für
  Textbereinigung ist die Luxusvariante, `qwen3.5:9b` passt auf die meisten Macs.
- Number One: Chat, eBook und Repo-RAG einheitlich auf `qwen3.6:35b`, Timeout 20 min.
- Log-Verify (`llm.py`) bleibt auf `gemma4:26b`.

### Teil A — Stille Post: keep_alive konfigurierbar — ERLEDIGT in 0.7.0

Umgesetzt und gegen ein echtes Ollama verifiziert. Der ausstehende Blick aufs
Dropdown im Bereinigungs-Tab ist am 2026-07-16 erfolgt (Daniel, an 0.8.0): ist da
und lesbar. Teil A ist damit vollständig abgeschlossen.

Bewusste Grenze (gilt weiter): Echte Ollama-*Daemon*-Konfiguration
(`OLLAMA_HOST=0.0.0.0`, globaler `OLLAMA_KEEP_ALIVE`, `ollama pull`) kann die App für
einen entfernten Host nicht setzen. Das gehört in die README-Anleitung (Teil C) und
in `doctor`-Warnungen, nicht in einen App-Eingriff in fremde Daemons.

### Teil B — Number One (liegt in theplan, nicht in diesem Repo)

Änderungen an theplan laufen über `$HOME/git/theplan/tools/command_queue.py add`
oder in einer theplan-Session, nicht als Direktedit aus diesem Repo.

- Chat-Default zurück auf `qwen3.6:35b`; Dropdown-Kennzeichnung anpassen, „⚡ immer
  warm" entfällt.
- `repo_rag.py` und `ebooks.py` von `gemma4:26b` auf `qwen3.6:35b` umstellen, ebenso
  die Statusanzeigen im `repo-rag`-Frontend.
- `DEFAULT_CHAT_KEEP_ALIVE` und `DEFAULT_RAG_KEEP_ALIVE` auf 20 min; `20*60` in
  `KEEP_ALIVE_CHOICES` aufnehmen.
- Preload-Endpoint, der das gewählte Modell asynchron lädt (leerer Generate,
  eingestelltes `keep_alive`, über die vorhandene `model_lifecycle`-Admission).
  Frontend feuert ihn beim ersten `input`-Ereignis einmal, entprellt, in Chat, eBook
  und Repo-RAG; nur für lokale Backends, nicht für Cloud-Modelle; Reset bei
  Modell- oder Backend-Wechsel.
- Zusätzlicher Button „Modell in den Speicher laden" in allen drei Oberflächen als
  Alternative zum Tippen, mit Tooltip: „Lädt das Modell schon jetzt in den Speicher —
  ein Tastendruck im Eingabefeld macht dasselbe."
- Speicherlage auf dem großen Host: `qwen3.6:35b` (~32 GB) und `gemma4:26b` (~18 GB)
  können gleichzeitig warm sein; bei 128 GB unkritisch.

### Teil C — README (beide Sprachen)

ERLEDIGT. Die vorhandene Sektion „Bereinigung auf einem stärkeren Rechner" trägt
jetzt die Schritt-für-Schritt-Anleitung für beide Seiten, die keep_alive-Erklärung
und den Hinweis auf die Hotkey-Aufnahme — in beiden Sprachen. Noch nicht auf GitHub
veröffentlicht (braucht einen ausdrücklichen Auftrag).

### Beobachtung, die zu Teil B gehört

Am 2026-07-15 gingen vom M3 aus rund 44 Anfragen pro Minute an das Ollama des
starken Macs, jeweils `POST /api/generate` gefolgt von `GET /api/tags`. `/api/tags`
ruft ausschließlich `stillepost-cli doctor` auf, die App selbst nie — es waren also
wiederholte `doctor`-Läufe. Wer sie im Sekundentakt gestartet hat, ist ungeklärt:
kein launchd-Job, kein Aufruf aus Number One. Der Burst endete von selbst und ist
seither nicht wiedergekehrt (Normalrate: 1 Request/Minute vom Warmhalte-Timer).

Relevant ist das, weil solche Anfragen ohne `keep_alive` das Modell auf Ollamas
Default von 5 Minuten zurücksetzen. Solange das passiert, wäre eine eingestellte
2-Stunden-Frist in der Praxis wirkungslos. Vor Teil B kurz prüfen, ob der Burst
wiederkehrt, und die Quelle finden.

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
2026-07-16 probiert, die App bleibt unauflösbar. Es gibt damit keinen bekannten Weg,
diese App per Computersteuerung zu testen.

Was bleibt: Daniel schaut selbst (dauert ~30 s), oder jemand baut einen Test-Hook
`STILLEPOST_DOCK_ICON=1`, der `setActivationPolicy(.accessory)` überspringt — dann
wäre die App für die Computersteuerung sichtbar. Passt zum vorhandenen Muster
(`STILLEPOST_OPEN_SETTINGS`, `STILLEPOST_OVERLAY_PREVIEW`, `STILLEPOST_NO_AX_PROMPT`,
`STILLEPOST_NO_MODEL_PROMPT`), ist aber bisher nicht gebaut und nicht beschlossen.

Erledigt am 2026-07-16 auf diesem Weg (Daniel am Schirm, an 0.8.0):

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

- Der echte Ab-/Anmeldezyklus für das Login-Item (Daniels Entscheidung: im Alltag,
  die Registrierung genügt als Beleg).

## Beim Dialog-Test aufgefallen (2026-07-16, unentschieden)

- **Die App hat kein Icon.** Kein `.icns` im Bundle, kein `CFBundleIconFile` in der
  Info.plist, keine Quelle im Repo, `build-app.sh` legt keins an — im Modell-Dialog
  steht deshalb ein generischer Platzhalter. Als Menüleisten-App (LSUIElement, kein
  Dock-Icon) fällt es meist nicht auf, sichtbar wird es aber im Modell-Dialog, in den
  Systemeinstellungen unter „Anmeldeobjekte“ und im Finder. Reine Politur, kein Fehler.
- **Größen stehen in MB, auch jenseits von 1 GB.** Der Dialog sagt „1549 MB“, die
  Commit-Historie und die READMEs sprechen von „1,6 GB“. Beides ist richtig (1549 MiB
  = 1,62 GB), aber der Nutzer denkt bei vierstelligen MB in GB. Eine Anzeige, die ab
  1024 MB auf GB wechselt, wäre freundlicher — wäre aber eine Verhaltensänderung samt
  Versions-Bump und ist deshalb nicht beiläufig gemacht worden.

## Weitere offene Arbeit

- Mehrtägigen Realbetrieb auf beiden vorgesehenen Macs durchführen und Befunde mit
  Datum, Build und Konfiguration notieren.
- Cleanup-Qualität und Latenz mit repräsentativen deutschen Diktaten messen und den
  Default `qwen3.5:9b` evidenzbasiert bestätigen oder korrigieren. Größere Modelle wie
  `gemma4:26b` sind dabei die Vergleichskandidaten, nicht die Baseline.
- READMEs (beide Sprachen): erklären, dass `qwen3.5:9b` der bewusste Default ist, weil
  er auf die meisten Macs passt, und wie man auf ein größeres Bereinigungsmodell wie
  `gemma4:26b` umstellt — samt ehrlicher RAM-Angabe (~18 GB nur für Textbereinigung)
  und dem Hinweis, dass das die Luxusvariante für starke Rechner ist.
- Login-Item: gebaut und verifiziert in 0.8.1. Offen bleibt nur das Deaktivieren im
  Alltag und der echte Ab-/Anmeldezyklus.
- Optional später: Live-Text-Anzeige und Silero-VAD evaluieren.

Erledigte Release-, README-, Lizenz-, GitHub- und Settings-Arbeit gehört in
Changelog/Release Notes, nicht zurück in diesen Backlog.
