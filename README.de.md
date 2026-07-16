# Stille Post

**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

Lokale Diktier-App für macOS: Globaler Hotkey, Spracherkennung mit Whisper und
Textbereinigung mit einem lokalen Sprachmodell. Der fertige Text landet direkt an
der Cursor-Position. Aufnahmen verlassen den Rechner nicht.

Ja, das ist vermutlich der millionste Whisper-Diktat-Klon. Der Unterschied liegt im
Anspruch: **Keine spürbare Wartezeit** nach dem Diktieren (auch bei langen Diktaten)
und eine Textbereinigung, die **putzt statt dichtet**. Gängige Diktat-Tools warten mit
der Verarbeitung, bis man fertig gesprochen hat, und ihre Bereinigungs-Modelle
formulieren um, kürzen oder „beantworten" das Diktat. Beides ist hier konstruktiv
ausgeschlossen.

## Wie die Wartezeit verschwindet

Stille Post verarbeitet das Audio **während** des Sprechens: Eine Stille-Erkennung
schneidet den Aufnahme-Strom an Sprechpausen in Segmente, jedes fertige Segment wird
sofort transkribiert, parallel zur weiterlaufenden Aufnahme. Beim Stopp ist die
Spracherkennung damit praktisch fertig; es folgt nur noch die Textbereinigung, die
bewusst **einmal über das ganze Diktat** läuft. Nur mit dem Gesamtzusammenhang kann
das Modell Satzzeichen korrekt setzen, statt an jeder Sprechpause einen falschen
Punkt zu hinterlassen. Zusätzlich wird das Bereinigungs-Modell schon beim
Aufnahme-**Start** vorgewärmt, damit kein Modell-Kaltstart in die Wartezeit fällt.

## Wie die Bereinigung ehrlich bleibt

1. Ein strikter, mit Beispielen abgesicherter System-Prompt: Nur Füllwörter,
   Versprecher, Stottern und Doppelungen entfernen; nie umformulieren, nie
   zusammenfassen, nie Fragen aus dem Diktat beantworten.
2. Eine **Plausibilitätsprüfung nach dem Modell**: Weicht die bereinigte Fassung in
   der Länge stark vom Rohtext ab (Indiz für Kürzen, Dazuerfinden oder „Antworten"),
   wird automatisch der Rohtext verwendet und das im Verlauf gekennzeichnet.
   Ein Diktat kann durch die Bereinigung nie zerstört werden.
3. Schlägt die Bereinigung fehl, wird immer der Rohtext eingefügt, nie nichts.
4. **Abweichungen sind sichtbar:** Das Overlay zeigt an, wenn die Bereinigung auf
   einen Ausweich-Endpoint wechselt oder unbereinigter Rohtext eingefügt wurde;
   der Verlauf speichert zu jedem Diktat den benutzten Endpoint und die Dauer.

## Features

- **Globaler Hotkey** (Standard ⌘⌥D, konfigurierbar): Aufnahme ein/aus.
- **Unübersehbarer Aufnahme-Indikator:** Großes rotes Overlay an der Mausposition
  (bei aktiver Bildschirm-Zoom-Funktion trotzdem sichtbar, weil der Zoom dem Cursor
  folgt) mit **Live-Mikrofonpegel**, an dem man sieht, dass wirklich Ton ankommt. Dazu
  deutlich unterscheidbare Start-/Stopp-/Fehler-Sounds und ein rotes Menüleisten-Symbol.
- **Stille-Erkennung:** Reine Stille wird nie an Whisper geschickt (keine
  Halluzinationen bei Denkpausen); nach längerer Abwesenheit stoppt die Aufnahme
  automatisch.
- **Verlauf mit Fenster:** Alle Diktate ansehen und kopieren (auch den Rohtext vor
  der Bereinigung), alles auf einen Klick löschen.
- **Aufnahmen werden sofort nach erfolgreicher Transkription gelöscht.** Nur bei
  einem Fehlschlag bleibt die Aufnahme erhalten und lässt sich im Verlauf per
  „Erneut transkribieren" nachholen. Klappt es, wird sie danach ebenfalls gelöscht.
- **Automatische Mikrofon-Wahl:** Es wird immer das im System eingestellte
  Standard-Mikrofon verwendet.
- **Datenschutz:** Spracherkennung und Bereinigung laufen komplett lokal. Optional
  lässt sich die Bereinigung an einen beliebigen OpenAI-kompatiblen Anbieter geben.
  Dann geht ausschließlich der transkribierte **Text** dorthin, niemals Audio.

## Menüleiste & Verlauf

| | |
|:---:|:---:|
| ![Menüleisten-Menü](assets/menu.jpg) | ![Verlauf-Fenster](assets/history.jpg) |
| *Menüleiste: Start/Stopp, Verlauf, Einstellungen, Beenden* | *Verlauf: jedes Diktat (roh + bereinigt), Kopieren per Klick* |

## Steuerbar ohne GUI (Skripte & AI-Agenten)

Die komplette Pipeline ist headless nutzbar, mit gleicher Logik und gleicher Konfiguration:

```bash
stillepost-cli doctor                  # prüft Abhängigkeiten (Exit-Code 0 = bereit)
stillepost-cli install-model           # Whisper-Modell laden (setzt Abbrüche fort)
stillepost-cli transcribe datei.wav    # WAV -> Text (mit Bereinigung) auf stdout
stillepost-cli transcribe datei.wav --raw
stillepost-cli cleanup "roher text"    # nur die Textbereinigung ("-" liest stdin)
stillepost-cli history list --json     # Verlauf maschinenlesbar
stillepost-cli history clear
stillepost-cli set-cleanup-key         # API-Key für Cloud-Bereinigung (liest stdin)
```

Diagnose geht nach stderr, das Ergebnis nach stdout, Fehler geben Exit-Code ≠ 0.
Gebaut für Pipes und Automatisierung. Die Umgebungsvariable `STILLEPOST_CONFIG`
zeigt auf eine alternative Konfigurationsdatei (z. B. für Tests).

Die CLI steckt im App-Bundle und liegt nicht von selbst im PATH. Einmalig verlinken:

```bash
sudo ln -sf /Applications/StillePost.app/Contents/MacOS/stillepost-cli \
            /usr/local/bin/stillepost-cli
```

Ohne Verlinkung geht auch der volle Pfad:
`/Applications/StillePost.app/Contents/MacOS/stillepost-cli doctor`

## Installation

Voraussetzungen: macOS 13+, [Homebrew](https://brew.sh), [Ollama](https://ollama.com).

```bash
brew install whisper-cpp          # lokaler Whisper-Server (whisper.cpp)
ollama pull qwen3.5:9b            # Standard-Bereinigungsmodell (~6 GB geladen — ein
                                  # vernünftiger Kompromiss, läuft gut auf 16–32-GB-Macs)
# Mehr Qualität und RAM übrig? gemma4:26b (~18 GB geladen, braucht einen
# 32-GB+-Mac) ist deutlich stärker; per config.json/Einstellungen wählbar.
scripts/build-app.sh --install    # baut die App und installiert nach /Applications
open /Applications/StillePost.app
```

Das Whisper-Modell fehlt in dieser Liste mit Absicht: Die App bietet beim ersten
Start an, es zu laden, falls es fehlt (`large-v3-turbo`, ~1,6 GB), und zeigt den
Fortschritt. Lieber selbst in der Hand oder auf mehreren Rechnern skriptbar?

```bash
scripts/install-model.sh                # aus dem Repo heraus, braucht nichts weiter
scripts/install-model.sh large-v3       # die einzige Alternative (~3,1 GB), siehe unten

# oder über die CLI (Pfad siehe „Steuerbar ohne GUI"):
stillepost-cli install-model
```

Beide Wege setzen abgebrochene Downloads fort und prüfen die Datei auf
Vollständigkeit — bei 1,6 GB will man nicht von vorn anfangen.

Ehrlich bleiben, was übrig bleibt: `brew install whisper-cpp` oben ist die **einzige
verbleibende Handarbeit**. Stille Post holt sein Modell selbst, installiert aber
nicht den whisper.cpp-Server für dich — die App greift nicht in fremde
Paketverwaltungen ein. `stillepost-cli doctor` sagt dir, wenn er fehlt.

Beim ersten Start fragt macOS nach zwei Berechtigungen: **Mikrofon** (Aufnahme) und
**Bedienungshilfen** (fürs Einfügen an der Cursor-Position per simuliertem ⌘V).

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
(das gezeigte Bereinigungsmodell ist nur ein Beispiel, keine Empfehlung):

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

## Entwicklung & Tests

```bash
swift test            # Unit-Tests (VAD, WAV, Plausibilitätsprüfung, Verlauf …)
scripts/e2e-test.sh   # Ende-zu-Ende: say-Stimme -> Whisper -> Bereinigung -> Prüfung
```

## Status

Früh, aber benutzbar. Geplant: Vergleichs-Benchmark (Qualität und Latenz) gegen
andere lokale Diktat-Tools und Cloud-Dienste.
