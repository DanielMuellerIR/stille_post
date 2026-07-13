# AGENTS.md: Stille Post

Stand: 2026-07-11

## Typ & Zweck
- **Typ:** GUI-App (+ CLI)
- **Zweck:** Lokale macOS-Diktier-App transkribiert Sprache mit Whisper und bereinigt den Text optional per LLM, bevor sie ihn zuverlässig am Cursor einfügt.
- **Plattform:** macOS-GUI, CLI

Lokale Diktier-App für macOS (Whisper-STT + LLM-Textbereinigung), gebaut als
qualitativ bessere Alternative zu bestehenden Diktat-Tools. Nutzer-Doku: README.de.md.

## Architektur

Swift Package (kein Xcode-Projekt), drei Targets:

- **`Sources/StillePostCore/`:** Gesamte Logik ohne GUI. CLI, App und Tests nutzen
  exakt denselben Code.
  - `DictationEngine.swift`: Orchestrierung; Streaming-Pipeline (Segmente werden
    WÄHREND der Aufnahme transkribiert; `SegmentCollector`-Actor sammelt Ergebnisse
    in Reihenfolge ein; LLM-Bereinigung einmal am Ende über den Gesamttext).
  - `VadSegmenter.swift`: RMS-basierte Stille-Erkennung (30-ms-Frames), schneidet an
    Sprechpausen, verwirft reine Stille, Abwesenheits-Auto-Stopp.
  - `AudioRecorder.swift`: AVAudioEngine, System-Standard-Mikro, live-Konvertierung
    auf 16 kHz mono Float.
  - `WhisperClient.swift` / `WhisperServerManager.swift`: HTTP zu whisper.cpp
    (`/inference`), Server wird bei Bedarf als Kindprozess gestartet; Artefakt-/
    Halluzinations-Filter.
  - `CleanupService.swift`: Bereinigung via Ollama (`/api/chat`, lokal oder anderer
    Rechner im LAN) ODER beliebiger OpenAI-kompatibler Endpoint; Endpoint-KETTE
    (primär + `fallbacks` aus der Config) wird der Reihe nach probiert, nicht
    erreichbare Endpoints kosten dank 2-s-Probe (`/api/version`) fast nichts;
    Vorwärmen nur des ersten erreichbaren Ollama-Endpoints (Laptop-RAM schonen);
    strikter System-Prompt; Plausibilitätsprüfung (Längen-Korridor) mit Fallback
    auf Rohtext; API-Key aus Env/Schlüsselbund.
  - `HistoryStore.swift`: Verlauf als JSON; Audio nur bei Fehlschlag zurückbehalten;
    je Eintrag Diagnose-Felder `cleanupEndpoint` + `cleanupSec` (seit 0.5.1; macht
    im Verlauf/CLI sichtbar, ob ein Diktat über einen Fallback lief und wie lange
    die Bereinigung brauchte).
  - `Config.swift`: JSON-Config, tolerantes Dekodieren (fehlende Felder = Defaults),
    `STILLEPOST_CONFIG`-Env-Override.
- **`Sources/StillePost/`:** Menüleisten-App (AppKit + SwiftUI): Carbon-Hotkey,
  Overlay-NSPanel (nonactivating, alle Spaces), Verlaufsfenster, Paste via ⌘V-Event,
  Einstellungsfenster (`SettingsWindow.swift`; Speichern schreibt config.json und
  baut Engine/Hotkey/Overlay/Verlauf komplett neu auf, siehe `buildComponents()`).
- **`Sources/stillepost-cli/`:** Headless-CLI (doctor/transcribe/cleanup/history/
  set-cleanup-key).

## Bauen / Testen

```bash
swift build               # Debug-Build (App + CLI)
swift test                # 21 Unit-Tests
scripts/e2e-test.sh       # Ende-zu-Ende mit say-Stimme (braucht Modell + Ollama)
scripts/build-app.sh      # Release + .app-Bundle; signiert automatisch mit Developer ID,
                          # falls im Schlüsselbund (sonst ad-hoc); --notarize + NOTARY_PROFILE
                          # für Notarisierung (Apple-Upload + stapler)
scripts/install-model.sh  # lädt ggml-large-v3-turbo von Hugging Face
```

Version: Zentrale `VERSION`-Datei (wird ins Info.plist übernommen).

## Entscheidungen (Warum)

- **Natives Swift statt Electron/Hammerspoon:** Zuverlässige globale Hotkeys ohne
  Zusatzrechte (Carbon `RegisterEventHotKey`), echtes Overlay über allen Spaces,
  brauchbares Verlaufs-GUI, kein Web-Stack-Overhead.
- **Streaming-Transkription, Bereinigung am Ende (seit 0.3.0):** Whisper läuft
  pro Segment schon während der Aufnahme; die LLM-Bereinigung läuft dagegen
  EINMAL über den zusammengefügten Gesamttext. Bis 0.2.x wurde pro Segment
  bereinigt; das erzeugte systematisch Punkte mitten im Satz (jede Denkpause
  = Segmentgrenze, jedes Fragment wurde isoliert zum "ganzen Satz" geputzt;
  kein Prompt/Modell kann das segment-lokal fixen). Tradeoff: Wartezeit nach
  dem Stopp wächst jetzt mit der Diktatlänge (LLM generiert den Gesamttext),
  Qualität geht vor; das Vorwärmen beim Aufnahme-Start bleibt.
- **Whisper-Modell `large-v3-turbo`:** STT ist nie der Flaschenhals (~0,2 s pro
  Segment auf Apple Silicon); der Flaschenhals ist immer das Cleanup-LLM.
- **Cleanup-Default `qwen3.5:9b` (Ollama):** Empirisch bester Kompromiss,
  schnell, und verfälscht keine Eigennamen. Modelle ≤4B ersetzen seltene Wörter
  durch ähnlich klingende oder kürzen radikal; Vorsicht bei Modellwechsel.
- **`think: false` im Ollama-Request:** Thinking-Modelle brauchen sonst >50 s
  statt <1 s fürs Putzen. Nicht-Thinking-Modelle ignorieren das Feld.
- **Plausibilitätsprüfung nach dem LLM:** Reale Fehlerfälle anderer Tools
  (Diktat gekürzt / beantwortet statt bereinigt) werden über einen
  Längen-Korridor erkannt -> automatischer Fallback auf Rohtext.
- **Audio-Handling:** Volle Aufnahme läuft als WAV auf Platte mit; Erfolg -> sofort
  löschen, Fehlschlag -> behalten für "Erneut transkribieren" (danach löschen).
- **Cloud-Bereinigung generisch (OpenAI-kompatibel):** Bewusst kein Anbieter
  hart verdrahtet; nur TEXT geht raus, nie Audio. Key nur Env/Schlüsselbund.
- **Fallback-Kette statt einem Provider (seit 0.4.0):** Auf schwächeren Macs war
  das lokale 9B-Modell der Engpass (Kaltstart + ~8 GB RAM-Dauerbelegung durch
  keep_alive:-1 → Speicherdruck, alles träge). Lösung: Bereinigung primär auf
  einem starken Rechner im LAN, `fallbacks` (lokal, dann optional Cloud) greifen
  bei Nichterreichbarkeit. Netzwerk-/Serverfehler ⇒ nächster Endpoint; ein
  Plausibilitäts-Verdacht dagegen ⇒ sofort Rohtext (Qualitätsproblem, kein
  Ausfall, also nicht die Kette weiterprobieren).
- **Primär-Endpoint: Direktanfrage statt Ping-vorweg (seit 0.6.0):** Die
  2-s-Erreichbarkeits-Probe war selbst der Schwachpunkt: Eine einzige
  WLAN-Latenzspitze (verlorener TCP-Handshake, Retransmit nach 1–2 s) sprengte
  ihr Budget und löste den teuren Fallback aus, obwohl die echte Anfrage den
  Aussetzer überlebt hätte (real: Server war 14 s nach der gescheiterten Probe
  wieder da, der lokale Kaltstart kostete 15 s). Deshalb: War der primäre
  Endpoint binnen 3 min erreichbar (Zeitstempel pflegt die Minuten-Warmhaltung),
  geht die /api/chat-Anfrage DIREKT raus, als **Stream** (NDJSON): Jedes
  Antwort-Häppchen ist ein Lebenszeichen, `timeoutIntervalForRequest` wirkt als
  LEERLAUF-Timeout (10 s ohne Daten = tot), die Generierung selbst darf beliebig
  lange dauern und der TCP-Handshake hat Luft für Retransmits. Scheitert der
  Versuch, folgt SOFORT ein zweiter über eine frische URLSession (falls eine
  gestorbene Pool-Verbindung schuld war; Overlay: ⚠️ zweiter Versuch), erst
  danach die Fallback-Kette. Ohne frischen Kontakt (unterwegs, App-Kaltstart)
  und für Fallback-Endpoints bleibt der alte Probe-Pfad OHNE Streaming, denn ein
  kalt startendes Fallback-Modell schweigt erst mal lange, dort wäre das
  Leerlauf-Timeout genau falsch. Parallel-Anfragen (hedged requests) bewusst
  nicht: Duplikate mit temperature 0 wären harmlos, aber der Direktversuch übersteht
  Spitzen jetzt von selbst; erst nachrüsten, falls der Verlauf scheiternde
  Zweitversuche zeigt.

## Fallen / Agent-Hinweise

- **Synthetisches ⌘V erreicht die Bildschirmfreigabe NICHT**, am entfernten Mac
  kommt nur ein nacktes „v" an. Beide Varianten real getestet und gescheitert:
  nur `flags = .maskCommand` auf dem V-Event UND echte ⌘-Down/-Up-Events mit
  Pacing (0.6.1). Die Bildschirmfreigabe reicht synthetische Modifier schlicht
  nicht weiter. Deshalb (seit 0.6.2): Ist ein Bildschirmfreigabe-Viewer vorn
  (`com.apple.ScreenSharing`/`com.apple.RemoteDesktop`), tippt die App bewusst
  GAR NICHT. Der Text bleibt in der Zwischenablage (der geteilte Sync trägt ihn
  rüber), das Overlay fordert zum manuellen ⌘V am entfernten Mac auf, und die
  alte Zwischenablage wird NICHT wiederhergestellt (Restore würde den Text vor
  dem manuellen Einfügen wieder wegsyncen). Siehe `PasteService.Outcome`.

- **`language=auto` erkennt die Sprache falsch und ÜBERSETZT dann**, bestätigt
  sowohl mit say-Kunststimmen als auch mit ECHTER deutscher Sprache (Nutzer-Test
  2026-07-10). Ursache: Unsere Streaming-Segmente sind kurz, die Erkennung hat
  wenig Material. Empfehlung an Nutzer: Sprache in der Config festnageln
  (`"language": "de"`); steht auch im README. Der E2E-Test setzt deshalb
  `language=de` (via `STILLEPOST_CONFIG`) und prüft Bereinigungs-Qualität separat
  über `stillepost-cli cleanup` mit echtem Text.
- **Wir setzen `num_ctx` explizit (Default 16384)**, denn Ollama-Installationen haben
  teils riesige globale Kontext-Defaults (real gesehen: 131072 → 9B-Modell belegt
  14 GB, Runner stirbt auf 18-GB-Macs mit "model runner has unexpectedly stopped").
  ACHTUNG: Ollama lädt pro `num_ctx`-Wert eine EIGENE Modell-Instanz; Warm-up-
  und Chat-Request müssen deshalb denselben Wert senden (tun sie).
- **`keep_alive`: primär `-1`, Fallbacks `"30m"`** (seit 0.5.1): Der primäre
  Endpoint bleibt dauerhaft warm; springt ein Fallback-Ollama nur wegen eines
  Netz-Aussetzers ein, soll sein Modell auf knappen Laptops nicht für immer
  ~8 GB RAM pinnen. Ein fremder Request mit `keep_alive: 0` auf dasselbe Modell
  hebt einen Pin generell auf; dagegen hält die App das Modell aktiv warm
  (seit 0.5.2, verschärft in 0.5.3): Warm-up beim App-Start + Re-Pin jede
  Minute (`warmUpTimer` im AppDelegate → `warmUp()` MIT Ketten-Durchfall).
  Übersteht Ollama-Neustarts; und fällt der primäre Rechner aus (WLAN weg,
  unterwegs), ist das Fallback-Modell binnen ~1 min vorgewärmt, denn sein
  Kaltstart (~35 s bei 6,6 GB auf RAM-knappem Laptop, real erlebt) fiele
  sonst mitten in die Wartezeit nach dem Diktat. Kleinere Fallback-Modelle
  sind KEINE Alternative: qwen3.5:4b/2b bauten im Test Grammatikfehler ein
  bzw. ließen Füllwörter stehen und verfälschten Namen.
- **Test-Target braucht `Tests/`-Ordner**, ohne ihn meldet SPM "overlapping
  sources" für das gesamte Package.
- **Schlüsselbund NIE im SwiftUI-Render-Pfad lesen:** `SecItemCopyMatching` kann
  einen modalen Berechtigungs-Dialog auslösen (z. B. wenn der Eintrag von einem
  anderen Binary angelegt wurde, hier: stillepost-cli). Im ersten Layout-Pass blockiert
  das das Fenster komplett (blieb real 0×0 unsichtbar). Keychain-Zugriffe nur
  asynchron und nur auf Nutzer-Aktion (siehe `APIKeyRow` in SettingsWindow.swift).
- **GUI-Checks headless:** Env `STILLEPOST_OPEN_SETTINGS=<tab>` (allgemein/
  bereinigung/spracherkennung/aufnahme) öffnet das Einstellungsfenster beim Start;
  `STILLEPOST_OVERLAY_PREVIEW=<zustand>` (processing-fallback/success-raw) zeigt
  das Overlay in einem Zustand, der sonst nur mitten im Diktat auftritt, für
  fenstergezielte Screenshots ohne Menü-Klickerei. Window-Owner heißt
  „Stille Post" (mit Leerzeichen, CFBundleName); das Overlay-Panel ist exakt
  340×110 (daran im Fenster-Listing erkennbar).
- **Berechtigungen (TCC) hängen an der Signatur-Identität:** Ad-hoc-signierte
  Builds bekommen bei JEDEM Neubau eine neue Identität → macOS fragt Mikrofon/
  Bedienungshilfen jedes Mal neu ab. Deshalb signiert build-app.sh mit Developer
  ID, sobald eine im Schlüsselbund liegt. Beim Wechsel der Identität (ad-hoc →
  Developer ID) fragt macOS EINMAL erneut, danach stabil.
- **Notarisierung:** Hardened Runtime blockt das Mikro ohne das Entitlement
  `com.apple.security.device.audio-input` (Resources/StillePost.entitlements);
  ALLE Binaries im Bundle einzeln signieren (auch stillepost-cli), sonst lehnt
  Apple ab. Signieren/Notarisieren geht nur in einer GUI-Session (über SSH ist
  die Login-Keychain gesperrt); für andere Macs das fertige Bundle kopieren.

## Offene Punkte / Roadmap

Erledigt 2026-07-10: GUI-Ersttest (Overlay/Tempo gut), Cloud-Provider-Praxistest
(OpenAI-kompatibel, Qualität gleichauf mit lokal, aber ~4x langsamer wegen
Zwangs-Thinking → lokal bleibt Default), MIT-Lizenz, Leak-Scan, eigene Sounds,
Developer-ID-Signatur + Notarisierung, Installation nach /Applications.

- [ ] Mehrtägiger Praxistest auf beiden Macs (läuft; Ausreißer sind seit 0.5.1
      im Verlauf per Endpoint + Dauer diagnostizierbar), danach:
- [ ] Entscheiden, ob das Default-Bereinigungsmodell von `qwen3.5:9b` auf
      `gemma4:e4b` umzieht (eigener Test 2026-07-11: schneller und wortgetreuer,
      braucht aber ~10 GB RAM geladen → Abwägung für kleine Macs; bei Umzug
      AGENTS.md-Entscheidungs-Sektion + READMEs anpassen)
- [x] GitHub-Veröffentlichung (2026-07-11)
- [ ] Benchmark-Suite: Qualität + Latenz vs. andere lokale Tools und Cloud-Dienste
      (Anspruch: Lokal besser als übliche lokale Setups, nahe an Top-Cloud)
- [x] Settings-GUI (seit 0.5.0: Menüpunkt „Einstellungen …", vier Bereiche inkl.
      Bereinigungs-Fallback-Kette und API-Key-Ablage in den Schlüsselbund)
- [ ] Hotkey-Aufnahme im GUI statt keyCode-Zahlen (im Settings-GUI derzeit
      Checkboxen + Keycode-Feld mit Live-Vorschau)
- [ ] Login-Item-Option (Autostart)
- [ ] Optional: Live-Text-Vorschau im Overlay (Segmente liegen während der
      Aufnahme schon vor; bewusst zurückgestellt)
- [ ] Optional: Silero-VAD statt RMS-Schwelle, falls die einfache Erkennung in
      lauter Umgebung zu oft anschlägt

## Verzeichnisstruktur

<!-- directory-structure: generated -->
- [AGENTS.md](AGENTS.md) — Projektprofil, Arbeitsregeln und dieses Datei-Verzeichnis.
- [README.de.md](README.de.md) — Projekt-Einstieg und Nutzerdokumentation.
- [README.md](README.md) — Projekt-Einstieg und Nutzerdokumentation.
- `Resources/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `Sources/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `Tests/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `scripts/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
<!-- /directory-structure -->
