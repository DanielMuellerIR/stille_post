# Stille Post

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Lokale Diktier-App für macOS: Globaler Hotkey, Spracherkennung mit Whisper und
Textbereinigung mit einem lokalen Sprachmodell. Der fertige Text landet direkt an
der Cursor-Position. Aufnahmen verlassen den Rechner nicht.

Die vollständige Oberfläche — Menü, Einstellungen, Verlauf, Overlays,
Modell-Download und nutzernahe Fehler — ist auf Deutsch und Englisch verfügbar.
macOS wählt die Sprache aus den systemweiten oder app-spezifischen
Spracheinstellungen. Auch die CLI-Diagnosen sind lokalisiert.

## Menüleiste & Verlauf

| | |
|:---:|:---:|
| ![Menüleisten-Menü](assets/menu.jpg) | ![Verlauf-Fenster](assets/history.jpg) |
| *Menüleiste: Start/Stopp, Verlauf, Einstellungen, Beenden* | *Verlauf: jedes Diktat (roh + bereinigt), Kopieren per Klick* |

## In fünf Minuten startklar

Das fertige, signierte App-Paket läuft auf **Apple-Silicon-Macs ab macOS 13**.
Für die aktuelle lokale Ollama-Version ist **macOS 14 oder neuer** erforderlich.
Ohne Ollama funktioniert die lokale Spracherkennung trotzdem; Stille Post fügt dann
den unbereinigten Whisper-Text ein.

### 1. Homebrew installieren

Falls Homebrew noch fehlt, folge der kurzen Anleitung auf [brew.sh](https://brew.sh).

### 2. Whisper installieren

```bash
brew install whisper-cpp
```

Das ist das lokale Spracherkennungsprogramm. Das dazugehörige Sprachmodell lädt
Stille Post später selbst.

### 3. Ollama installieren und starten

[Ollama für macOS herunterladen](https://ollama.com/download/mac), nach
`/Applications` verschieben und einmal öffnen. Ollama bereinigt später nur den
fertigen Text; Audio wird nie an Ollama gesendet.

### 4. Bereinigungsmodell herunterladen

```bash
ollama pull qwen3.5:9b
```

Das Standardmodell belegt etwa 6,6 GB auf der Festplatte und passt auf die meisten
Macs mit 16–32 GB Arbeitsspeicher.

### 5. Stille Post installieren

1. Das aktuelle DMG unter
   [GitHub Releases](https://github.com/DanielMuellerIR/stille_post/releases/latest)
   laden.
2. DMG öffnen und **Stille Post** in **Programme** ziehen.
3. Stille Post starten. Beim ersten Start den Download von `large-v3-turbo`
   bestätigen (~1,6 GB) und **Mikrofon** sowie **Bedienungshilfen** erlauben.

Danach: Cursor in ein Textfeld setzen, **⌘⌥D** drücken, sprechen und **⌘⌥D**
erneut drücken. Der Text wird an der Cursor-Position eingefügt.

Stille Post sucht höchstens täglich nach signierten Updates und installiert nichts
ungefragt. Eine sofortige Prüfung ist jederzeit im Menü unter **„Nach Updates
suchen …“** möglich; Download, Austausch der App und Neustart übernimmt Sparkle
erst nach Zustimmung.

> **Warum werden zwei Modelle geladen?** `large-v3-turbo` versteht die Sprache und
> erzeugt den Rohtext. `qwen3.5:9b` entfernt danach Füllwörter, Versprecher und
> Wiederholungen. Beide laufen lokal.

## Was Stille Post besonders macht

- **Schnell fertig:** Whisper transkribiert schon während der Aufnahme.
- **Bereinigt ohne umzuschreiben:** Das Sprachmodell entfernt Versprecher und
  Füllwörter, soll den Inhalt aber weder kürzen noch beantworten.
- **Sicherer Rückfall:** Wirkt das bereinigte Ergebnis unplausibel oder ist der
  Dienst nicht erreichbar, wird der Whisper-Rohtext verwendet.
- **Lokal und nachvollziehbar:** Audio bleibt immer auf dem Mac. Der Verlauf zeigt
  Rohtext, Ergebnis und den verwendeten Bereinigungs-Endpunkt.
- **Sichtbare Aufnahme:** Overlay, Mikrofonpegel, Menüleisten-Symbol und
  unterschiedliche Klänge zeigen den aktuellen Zustand.
- **Kein Audio-Müll:** Erfolgreich verarbeitete Aufnahmen werden sofort gelöscht;
  nach Fehlern bleiben sie für eine erneute Transkription erhalten.

## Wie die kurze Wartezeit entsteht

Eine Stille-Erkennung schneidet die laufende Aufnahme an Sprechpausen in Segmente.
Jedes fertige Segment wird sofort transkribiert, während die Aufnahme weiterläuft.
Nach dem Stopp bereinigt das Sprachmodell den **vollständigen** Text genau einmal,
damit Zusammenhang und Satzgrenzen erhalten bleiben. Das Bereinigungsmodell wird
bereits beim Start der Aufnahme vorgewärmt.

## Wie die Bereinigung abgesichert ist

1. Der System-Prompt erlaubt nur das Entfernen von Füllwörtern, Versprechern,
   Stottern und Doppelungen – kein Umformulieren, Zusammenfassen oder Beantworten.
2. Eine Plausibilitätsprüfung vergleicht die Länge mit dem Rohtext. Bei starken
   Abweichungen wird automatisch der Rohtext verwendet.
3. Schlägt die Bereinigung fehl, wird ebenfalls der Rohtext eingefügt.
4. Overlay und Verlauf kennzeichnen Ausweich-Endpunkte und Rohtext-Rückfälle.

### Welches Whisper-Modell?

Bewusst nur zwei — eine lange Modell-Liste schiebt die Entscheidung nur auf dich ab:

| Modell | Größe | Wann |
|---|---|---|
| `large-v3-turbo` | ~1,6 GB | **Standard.** Beste Mischung aus Qualität und Tempo. |
| `large-v3` | ~3,1 GB | Nur, wenn Fremdwörter und Fachbegriffe besser sitzen müssen. Langsamer. |

Kleinere Modelle gibt es nicht: Schlechtere Erkennung will niemand, und so groß ist
Turbo nicht.

## Konfiguration

Alle Einstellungen gibt es im Menüleisten-Menü unter **„Einstellungen …"** als
Dialog. Darunter liegt `~/Library/Application Support/StillePost/config.json`
(entsteht beim ersten Start, Menüpunkt „Konfigurationsdatei öffnen"). Die Datei
bleibt von Hand editierbar.

Der Dialog ist in vier Tabs gegliedert, die üblichen Fälle brauchen also kein JSON
(das gezeigte Bereinigungsmodell ist der Standard):

| | |
|:---:|:---:|
| ![Tab Allgemein](assets/settings-general.jpg) | ![Tab Bereinigung](assets/settings-cleanup.jpg) |
| *Allgemein — Aufnahme-Hotkey & Overlay* | *Bereinigung — Anbieter, Modell, Kontext, Fallbacks* |
| ![Tab Spracherkennung](assets/settings-speech.jpg) | ![Tab Aufnahme](assets/settings-recording.jpg) |
| *Spracherkennung — Sprache & Whisper-Server* | *Aufnahme — Stille-Erkennung & Auto-Stopp* |

Die wichtigsten Schalter:

| Bereich | Feld | Bedeutung |
|---|---|---|
| `hotkey` | `keyCode`, `modifiers` | Aufnahme-Hotkey (Default ⌘⌥D). Im Tab „Allgemein“ nimmt „Hotkey aufnehmen“ die gedrückte Kombination auf — man muss keine Tastencodes nachschlagen |
| `whisper` | `language` | `"auto"` oder fest z. B. `"de"`. **Empfehlung: Festnageln.** Bei `auto` rät Whisper die Sprache pro Sprech-Segment und übersetzt bei Fehl-Erkennung ungefragt |
| `cleanup` | `enabled` | Bereinigung an/aus |
| `cleanup` | `provider` | `"ollama"` (lokal/eigenes Netz) oder `"openai"` (Cloud, nur Text) |
| `cleanup` | `model` | Ollama-Modellname |
| `cleanup` | `ollamaURL` | Ollama-Endpoint; darf auch ein anderer Rechner im eigenen Netz sein |
| `cleanup` | `keepAlive` | wie lange Ollama das Modell nach einem Diktat im Speicher behält: `"2h"` (Default), `"20m"`, `"0"` (sofort entladen) oder `"-1"` (nie entladen). Wird bei jeder Anfrage mitgeschickt — in Ollama ist dafür nichts einzustellen |
| `cleanup.remote` | `baseURL`, `model` | OpenAI-kompatibler Anbieter |
| `cleanup` | `fallbacks` | Ausweich-Endpoints, falls der primäre nicht antwortet (s. u.) |
| `vad` | `autoStopAfterSilenceSec` | Abwesenheits-Stopp (0 = aus) |
| `ui` | `overlayPosition` | `"mouse"` oder `"bottomCenter"` |

Cloud-Bereinigung einrichten (Beispiel, funktioniert mit jedem OpenAI-kompatiblen
Anbieter):

```jsonc
"cleanup": {
  "provider": "openai",
  "remote": { "baseURL": "https://api.example.com/v1", "model": "modell-name" }
}
```

Der API-Key kommt **nicht** in die Datei, sondern in den Schlüsselbund
(`stillepost-cli set-cleanup-key`) oder in die Umgebungsvariable
`STILLEPOST_CLEANUP_API_KEY`.

### Bereinigung auf einem stärkeren Rechner (mit Fallback)

Auf einem schwächeren Laptop lohnt es sich, die Bereinigung an einen stärkeren
Rechner im eigenen Netz abzugeben: Dort kann das größere, hochwertigere Modell
laufen (z. B. gemma4:26b), und der Laptop behält die ~6 GB RAM für sein leichtes
lokales Fallback.

**Auf dem starken Rechner** (der bedient — er braucht selbst kein Stille Post):

1. Modell ziehen: `ollama pull gemma4:26b`
2. Ollama auf dem Netz-Interface lauschen lassen statt nur auf localhost:
   `OLLAMA_HOST=0.0.0.0` setzen, oder in der Ollama-App den Schalter
   „Expose Ollama to the network".
3. Von einem anderen Mac aus prüfen:
   `curl http://<ip-des-starken-macs>:11434/api/version`

Mehr ist dort nicht nötig — Modell, Kontextgröße und keep_alive schickt Stille Post
bei jeder Anfrage mit.

**Auf jedem Mac, auf dem du diktierst:** Stille Post installieren, dann unter
Einstellungen → Bereinigung den Endpoint des starken Rechners eintragen
(`http://<ip>:11434`), dazu Modell und auf Wunsch die Ladedauer.
`stillepost-cli doctor` prüft die ganze Kette und sagt, ob der Endpoint antwortet
und das Modell vorhanden ist.

**Wie lange das Modell geladen bleibt**, steuert im selben Tab das Feld
„Geladen lassen" (keep_alive). Der Default von 2 Stunden ist ein Kompromiss:
Diktiert man innerhalb dieser Zeit erneut, antwortet das Modell sofort; danach gibt
Ollama den Speicher von selbst frei. „Dauerhaft geladen" gibt ihn nie her — die
richtige Wahl, wenn RAM übrig ist. Spürbar ist der Unterschied selten, denn Stille
Post beginnt das Modell zu laden, sobald du den Hotkey drückst: Es lädt, während du
noch sprichst.

`fallbacks` listet Ausweich-Endpoints, die der Reihe nach probiert werden, wenn der
primäre nicht antwortet (Probe-Timeout 2 s; unterwegs ohne Heimnetz übernimmt also
fast verzögerungsfrei das lokale Ollama):

```jsonc
"cleanup": {
  "ollamaURL": "http://192.168.1.50:11434",   // starker Rechner im LAN (primär)
  "model": "gemma4:26b",
  "keepAlive": "2h",                          // "-1" = dauerhaft geladen halten
  "fallbacks": [
    { "provider": "ollama", "ollamaURL": "http://127.0.0.1:11434", "model": "qwen3.5:9b" },
    { "provider": "openai", "remote": { "baseURL": "https://api.example.com/v1", "model": "modell-name" } }
  ]
}
```

Über das eigene Netz geht dabei nur transkribierter TEXT, nie Audio — die
Spracherkennung läuft immer auf dem Rechner, auf dem du diktierst. Welcher Endpoint
zum Zug kam, zeigt `stillepost-cli cleanup` an und das Verlaufsfenster.

## Steuerbar ohne GUI

Die komplette Pipeline ist mit derselben Logik und Konfiguration per CLI nutzbar:

```bash
stillepost-cli doctor                  # prüft Abhängigkeiten (Exit-Code 0 = bereit)
stillepost-cli install-model           # Whisper-Modell laden (setzt Abbrüche fort)
stillepost-cli transcribe datei.wav    # WAV -> bereinigter Text auf stdout
stillepost-cli transcribe datei.wav --raw
stillepost-cli cleanup "roher text"    # nur Bereinigung ("-" liest stdin)
stillepost-cli history list --json
stillepost-cli history clear
stillepost-cli set-cleanup-key         # API-Key aus stdin in den Schlüsselbund
```

Diagnosen gehen nach stderr, Ergebnisse nach stdout, Fehler liefern einen Exit-Code
≠ 0. Die CLI steckt im App-Bundle und liegt nicht automatisch im PATH:

```bash
sudo ln -sf /Applications/StillePost.app/Contents/MacOS/stillepost-cli \
            /usr/local/bin/stillepost-cli
```

Ohne Verlinkung funktioniert auch
`/Applications/StillePost.app/Contents/MacOS/stillepost-cli doctor`. Mit
`STILLEPOST_CONFIG` lässt sich eine alternative Konfigurationsdatei angeben.

## Entwicklung & Tests

```bash
git clone https://github.com/DanielMuellerIR/stille_post.git
cd stille_post
scripts/build-app.sh --install   # Release-Build nach /Applications installieren
swift test            # Unit-Tests (VAD, WAV, Plausibilitätsprüfung, Verlauf …)
scripts/e2e-test.sh   # Ende-zu-Ende: say-Stimme -> Whisper -> Bereinigung -> Prüfung
```

Der Sparkle-Feed und seine Release-Automation sind in
[`docs/sparkle-release.md`](docs/sparkle-release.md) beschrieben.

## Status

Früh, aber benutzbar. Geplant: Vergleichs-Benchmark (Qualität und Latenz) gegen
andere lokale Diktat-Tools und Cloud-Dienste.
