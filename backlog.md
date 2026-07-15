# Aktiver Backlog

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

### Teil A — Stille Post: keep_alive konfigurierbar

- Feld `keepAlive: String` in `Config.Cleanup` (Primär) und `Config.Cleanup.Endpoint`
  (Fallbacks), tolerant dekodiert. Werte in Ollama-Schreibweise: `"-1"`, `"2h"`,
  `"20m"`, `"0"`. Beim Senden numerische Werte (`-1`, `0`) als Zahl, Dauer-Strings
  als String — Ollama akzeptiert beides, aber nicht `"-1"` als String.
- `CleanupService.keepAliveValue(pinForever:)` liest künftig `endpoint.keepAlive`
  statt der fest verdrahteten Konstante. Warm-up und Chat müssen denselben Wert
  senden, genau wie schon bei `num_ctx`.
- Der 60-Sekunden-Re-Pin in `AppDelegate` läuft **nur noch, wenn `keepAlive == "-1"`**.
  Bei einem endlichen Timeout darf kein periodisches Re-Pinnen stattfinden, sonst
  läuft das Fenster nie ab (CLAUDE.md: „periodischer Warm-up darf diese Semantik
  nicht aushebeln").
- Das Vorwärmen beim Diktat-Start bleibt unverändert — es existiert bereits in
  `DictationEngine.start()` und ist genau das gewünschte „lädt, während man redet".
- Settings-UI im Bereinigungs-Tab neben `num_ctx`: Dropdown „dauerhaft / 2 h / 1 h /
  30 min / 20 min / 5 min / sofort entladen", pro Endpoint.
- Bewusste Grenze: Echte Ollama-*Daemon*-Konfiguration (`OLLAMA_HOST=0.0.0.0`,
  globaler `OLLAMA_KEEP_ALIVE`, `ollama pull`) kann die App für einen entfernten Host
  nicht setzen. Das gehört in die README-Anleitung und in `doctor`-Warnungen
  (Endpoint erreichbar? Modell vorhanden?), nicht in einen App-Eingriff in fremde
  Daemons. Pro-Request-Parameter (`keep_alive`, `num_ctx`) macht die App dagegen
  bereits vollständig selbst.
- Tests: `keepAlive` kommt aus der Config; Warm-up und Chat teilen `keep_alive` und
  `num_ctx`; endlicher Wert erzeugt kein Re-Pinnen. Dazu `swift test` und
  `scripts/e2e-test.sh`, danach VERSION-Bump.

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

Neue Sektion „Cleanup auf einem starken Mac im LAN": starken Mac einrichten (Modell
ziehen, Ollama im Netz freigeben, `keep_alive` in den Stille-Post-Einstellungen
wählen), danach auf weiteren Macs im selben Netz Stille Post installieren und dort
den Endpoint des starken Macs eintragen. Erklären, dass das Vorwärmen beim Diktat-
Start das entfernte Modell lädt, während man spricht, und dass nur Text das Gerät
verlässt, nie Audio.

## Weitere offene Arbeit

- Mehrtägigen Realbetrieb auf beiden vorgesehenen Macs durchführen und Befunde mit
  Datum, Build und Konfiguration notieren.
- Cleanup-Qualität und Latenz mit repräsentativen deutschen Diktaten messen und die
  Modellwahl `gemma4:26b` gegen Kandidaten wie `qwen3.5:9b` evidenzbasiert bestätigen
  oder korrigieren.
- GUI-Hotkey-Recorder fertigstellen und als echtes App-Bundle prüfen.
- Login-Item ergänzen und Start-/Deaktivierungsverhalten testen.
- Optional später: Live-Text-Anzeige und Silero-VAD evaluieren.

Erledigte Release-, README-, Lizenz-, GitHub- und Settings-Arbeit gehört in
Changelog/Release Notes, nicht zurück in diesen Backlog.
