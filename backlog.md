# Aktiver Backlog

## „Vielen Dank" erscheint in Diktaten (befundet 2026-07-15, noch nicht behoben)

Betrifft rund jedes dritte Diktat (11 von 29 Verlaufseinträgen). Es sind ZWEI
unabhängige Fehler, die nur zusammen dieses Bild ergeben.

### Repro (billig und zuverlässig)

Fünf Sekunden digitale Stille genügen — kein Mikrofon, kein Raum nötig:

```bash
python3 - <<'PY'
import wave, struct
with wave.open("/tmp/silence.wav","w") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(struct.pack("<%dh" % (16000*5), *([0]*(16000*5))))
PY
curl -s http://127.0.0.1:8181/inference -F file=@/tmp/silence.wav \
     -F response_format=json -F temperature=0 -F language=de
# liefert: {"text":" Vielen Dank.\n"}
```

Wichtig für die Lösungssuche: Eine Konfidenz-Schwelle hilft NICHT. Bei genau dieser
Stille meldet Whisper `no_speech_prob: 2.95e-08` und `avg_logprob: -0.25` — es ist
sich absolut sicher, Sprache gehört zu haben. `verbose_json` liefert diese Felder,
aber sie taugen hier nicht als Signal.

### Fehler 1 — Whisper bekommt Stille, die es nie sehen dürfte

`VadSegmenter.closeSegment` kürzt die Stille am Segmentende nur
`if reason == .pause`. Beim Stopp der Aufnahme (`.flush`) und am 30-s-Limit
(`.maxLength`) bleibt sie im Segment und geht an Whisper. Dazu passt die
Positionsverteilung im Verlauf: 7 von 11 Fällen kleben am ENDE des Textes, 2 am
Anfang, 2 mittendrin, 0 stehen allein.

Belegt: dass Whisper auf Stille halluziniert und dass dieser Trim fehlt.
Hypothese: dass genau dieser Pfad die beobachteten Fälle erzeugt. Vor dem Fix mit
einer WAV aus „okay" + 10 s Stille durch beide Pfade nachweisen.

Fix: Stille am Segmentende bei JEDEM Schließgrund auf `paddingSec` kürzen. Dabei
auch prüfen, ob die Stille am Segment-ANFANG gekürzt gehört (Aufnahmestart bis zum
ersten Wort ist heute ungekürzt). Testbar in `VadSegmenterTests`.

### Fehler 2 — die Bereinigung löscht echten Text

Der schlimmere Teil. Verlaufseintrag 2026-07-15T19:38:06:

```
rawText   (Whisper):     "Okay. Vielen Dank."
cleanText (Bereinigung): "Vielen Dank."
```

Whisper hatte das gesprochene „Okay." korrekt erfasst; die Bereinigung hat es
gelöscht und die Halluzination behalten. Die Plausibilitätsprüfung
(`CleanupService.sanityCheckFailure`) erlaubt bei Rohtexten unter 60 Zeichen
Schrumpfung bis auf 20 % — 18 → 12 Zeichen rutscht durch.

Fix: Korridor für kurze Texte enger ziehen, ohne den legitimen Fall zu brechen
(„ähm ja Punkt" → „Ja." ist gewollt und steht als Kommentar im Code). Ein Diktat
darf nie Inhalt verlieren; im Zweifel Rohtext liefern.

### Fehler 3 — der Artefakt-Filter kann prinzipiell nicht greifen

`WhisperClient.cleanWhisperArtifacts` kennt `"vielen dank fürs zuschauen"`, aber
nicht das nackte `"vielen dank"` — und vergleicht auf exakte Gleichheit der GANZEN
Ausgabe. Da die Floskel immer an echtem Text klebt (0 von 11 Fällen standen allein),
greift der Filter nie.

Fix zuletzt und vorsichtig: die Floskel auch als führenden/schließenden Satz
entfernen. Heikel, weil „Vielen Dank." am Ende eines Diktats echt gemeint sein kann.
Am liebsten nur anwenden, wenn Stille im Spiel war — sonst löscht die App echten
Text, und das ist genau der Fehler, den wir gerade beheben. Erst Fehler 1 lösen und
messen, ob danach überhaupt noch etwas übrig bleibt.

### Whisper-Modellwechsel — beantwortet, aber schwach

Läuft bereits auf `large-v3-turbo`. Nach oben gäbe es nur das volle `large-v3`
(~3 GB, nicht lokal vorhanden). Die Stille-Halluzination ist bei allen
Whisper-Modellen dokumentiert und steckt in den Trainingsdaten (YouTube-Untertitel),
nicht in der Modellgröße — ein Wechsel würde sie höchstens seltener machen, nicht
beheben. Fehler 1 zuerst. Falls danach noch gemessen werden soll: Der Repro oben
eignet sich als Prüfstein, und die Repo-Regel verlangt ohnehin Qualitäts- UND
Latenzmessung vor einem Wechsel.

### Nebenbefund: Modellpfad hängt an OpenWhispr

`~/Library/Application Support/StillePost/models/ggml-large-v3-turbo.bin` ist ein
Symlink nach `~/.cache/openwhispr/whisper-models/`. Wird OpenWhispr deinstalliert
oder räumt seinen Cache, verliert Stille Post sein Modell. Eigene Kopie erwägen.

## Warm-on-Intent statt Dauer-Pin (beschlossen 2026-07-15, noch nicht umgesetzt)

Ziel: Das Bereinigungsmodell soll nicht mehr dauerhaft im Speicher hängen, sondern
nach einem Timeout entladen werden. Die Wartezeit wird dadurch nicht spürbar, weil
das Modell bereits beim Diktat-Start vorgeladen wird — es lädt, während man spricht.

Beschlossene Eckwerte (Entscheidungen von Daniel, nicht neu verhandeln):

- Stille-Post-Default für `keep_alive`: **2h** am Primär-Endpoint, **30m** an den
  Fallbacks (heutiges Fallback-Verhalten).
- Cleanup-Modell bleibt `gemma4:26b`.
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
- Cleanup-Qualität und Latenz mit repräsentativen deutschen Diktaten messen und die
  Modellwahl `gemma4:26b` gegen Kandidaten wie `qwen3.5:9b` evidenzbasiert bestätigen
  oder korrigieren.
- Login-Item ergänzen und Start-/Deaktivierungsverhalten testen.
- Optional später: Live-Text-Anzeige und Silero-VAD evaluieren.

Erledigte Release-, README-, Lizenz-, GitHub- und Settings-Arbeit gehört in
Changelog/Release Notes, nicht zurück in diesen Backlog.
