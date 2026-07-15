# Aktiver Backlog

## Whisper-Modell selbst beschaffen (Entscheidung 2026-07-15, noch nicht umgesetzt)

Ziel: Stille Post soll auf einem nackten Mac benutzbar sein, ohne dass man sich
selbst um Whisper kümmert. Heute funktioniert die App nur, weil vorher OpenWhispr
das Modell installiert hatte — das ist kein Zustand für andere Nutzer.

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

Ist-Zustand, damit niemand doppelt sucht:

- `scripts/install-model.sh` lädt bereits `large-v3-turbo` von Hugging Face und
  nimmt einen Modellnamen als Argument. `scripts/install-model.sh large-v3` lädt
  also schon heute das volle Modell — danach muss `whisper.modelPath` in der
  config.json darauf zeigen.
- **Bug im Skript:** Zeile 14 prüft `if [ -f "$DEST" ]`. Das ist auch für einen
  SYMLINK wahr. Auf Daniels M3 zeigt der Modellpfad auf
  `~/.cache/openwhispr/whisper-models/` — das Skript meldet deshalb „Modell ist
  schon da" und lädt nie. Vor jeder Messung sicherstellen, dass wirklich eine
  eigene Kopie liegt.
- Die App selbst kann nichts laden. Wer nur die `.app` installiert (der normale
  Weg für andere Nutzer), steht ohne Modell da.
- **Der Modellpfad hängt an OpenWhispr:**
  `~/Library/Application Support/StillePost/models/ggml-large-v3-turbo.bin` ist auf
  dem M3 ein Symlink nach `~/.cache/openwhispr/whisper-models/`. Räumt OpenWhispr
  seinen Cache, verliert Stille Post sein Modell.

Zu bauen:

- Modell-Download in die App bzw. die CLI holen, mit Fortschrittsanzeige und
  Wiederaufnahme; Zielpfad ist `whisper.modelPath`. Beim ersten Start anbieten,
  wenn das Modell fehlt — nicht ungefragt 1,6 GB ziehen.
- `stillepost-cli doctor` soll das fehlende Modell nicht nur melden, sondern das
  Nachladen anbieten (die CLI ist der skriptbare Weg, siehe Repo-Regel).
- Ehrlich bleiben: Das Modell ist nur die halbe Miete. Der `whisper-server` kommt
  weiterhin aus Homebrew (`brew install whisper-cpp`). Entweder das mit abdecken
  oder im README klar als einzige verbleibende Voraussetzung nennen.
- READMEs (beide Sprachen) entsprechend anpassen.

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

Umgesetzt und gegen ein echtes Ollama verifiziert. Offen bleibt nur eines: Der
GUI-Smoke-Test des neuen Dropdowns wurde nicht visuell durchgeführt, weil die App
als Menüleisten-App nicht im Spotlight-Index steht und der Screenshot-Weg deshalb
nicht griff. Das Verhalten dahinter ist per Log-Messung belegt; ein Blick auf das
Dropdown im Bereinigungs-Tab beim nächsten echten App-Start genügt.

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
- Login-Item ergänzen und Start-/Deaktivierungsverhalten testen.
- Optional später: Live-Text-Anzeige und Silero-VAD evaluieren.

Erledigte Release-, README-, Lizenz-, GitHub- und Settings-Arbeit gehört in
Changelog/Release Notes, nicht zurück in diesen Backlog.
