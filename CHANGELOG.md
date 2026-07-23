# Changelog

Produktgeschichte von Stille Post. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei wurde am 2026-07-16 nachträglich aus den Commit-Messages
rekonstruiert (0.6.2 bis 0.8.1). Die ausführliche Begründung jeder Entscheidung —
Messwerte, verworfene Alternativen, Fallstricke — steht im jeweils genannten
Commit; hier steht nur, was sich für den Nutzer geändert hat. Ab 0.8.2 wird die
Datei mit dem Versions-Bump fortgeschrieben.

## [0.8.12] — 2026-07-23

### Geändert

- Das Standard-Bereinigungsmodell ist jetzt `gemma4:e4b-it-qat` (öffentlich beziehbar,
  ~6 GB) statt `qwen3.5:9b`. Ein Benchmark über 12 lokale Modelle (siehe
  [docs/cleanup-model-benchmark.md](docs/cleanup-model-benchmark.md)) zeigte: Ein
  diszipliniertes kleines Modell putzt treuer und schneller als die großen, die
  gesprochenen Text ungefragt umschreiben („M-Dashes" → „Gedankenstriche",
  Pluralisieren). `Config.swift`, beide READMEs, `AGENTS.md` und der Backlog nennen jetzt
  das neue Modell.
- Die frühere README-Darstellung „auf einem stärkeren Rechner läuft ein größeres,
  hochwertigeres Modell (z. B. `gemma4:26b`)" wurde als sachlich falsch korrigiert:
  Die Bereinigung auf einen anderen Rechner auszulagern spart nur lokalen RAM — es läuft
  dort dasselbe kleine Modell, das für diese Aufgabe ohnehin besser putzt.

## [0.8.11] — 2026-07-23

### Geändert

- Die Worttreue-Prüfung der Bereinigung ist toleranter. Sie richtet Roh- und
  Ausgabewörter aus und lässt jetzt eng begrenzte Reparaturen von Whisper-Artefakten
  durch: an Sprechpausen zerhackte Komposita (»dauer haft« → »dauerhaft«), einen
  einzelnen Verhörer (»olama« → »ollama«) und kurze Flexionsendungen (»ein« →
  »einen«). Echtes Umschreiben, Übersetzen, Umstellen oder Ergänzen führt weiterhin
  zum Rohtext-Rückfall; Modell- und Versionskennungen mit Ziffern (»426b«, »id3«)
  bleiben unantastbar. Dadurch überstehen deutlich mehr lange, technische Diktate die
  Prüfung, ohne dass ein Modell den Inhalt verändern kann. Die Längenkorridor-Prüfung
  bleibt als zusätzliche Sicherheitsgrenze bestehen.
- Beide READMEs beschreiben die Prüfung neu. Das neue
  [docs/cleanup-model-benchmark.md](docs/cleanup-model-benchmark.md) hält den
  Modell-Benchmark über 12 lokale Modelle und die Begründung des toleranten Wächters
  reproduzierbar fest.

## [0.8.10] — 2026-07-22

### Sicherheit

- Whisper-Audio darf ausschließlich an einen expliziten lokalen HTTP-Endpunkt auf
  `127.0.0.0/8` oder `::1` mit Port gehen. App, Einstellungen, CLI und Autostart
  lehnen Netzwerk-, HTTPS- und mehrdeutige Hostnamen vor jedem Request sichtbar ab.
- Die Appcast-Automation gibt den privaten Sparkle-Schlüssel nur noch an den
  Signierschritt weiter und bindet fremde Actions an feste Commit-Stände. Vor der
  Update-Signatur müssen Tag und Bundle-Version, Bundle- und Team-ID,
  Developer-ID-Signaturen, Notary-Tickets und Gatekeeper-Prüfungen stimmen.
- `--install` ist nur noch zusammen mit einer erfolgreichen Notarisierung möglich.
  Der nochmals geprüfte Build wird unter `/Applications` vollständig bereitgestellt
  und anschließend atomar ausgetauscht.

### Behoben

- Ein während Start oder Nachverarbeitung abgebrochenes Diktat kann danach weder
  im Verlauf landen noch verspätet in eine andere aktive Anwendung eingefügt werden.
- Die Zwischenablage wird mit allen Items und Typdaten wiederhergestellt; eine neue
  Kopieraktion während des Einfügens wird nicht mehr überschrieben.
- App und CLI verändern den Verlauf unter einem gemeinsamen Prozess-Lock und laden
  vor jeder Mutation frisch von Platte. Schreibfehler werden sichtbar gemeldet,
  und Audio wird erst nach bestätigter Persistenz gelöscht.
- Anlage, fortlaufendes Schreiben und Finalisierung der Diagnose-WAV werden geprüft.
  Unvollständige Dateien bleiben zur Diagnose erhalten, werden aber nie als sichere
  Wiederholungsquelle angeboten.
- Ollama-Streams benötigen ein ausdrückliches `done: true`. Abgebrochene Antworten,
  ungültige Frames und Provider-Fehler verwerfen jeden Teiltext und wechseln in den
  vorgesehenen Retry-/Fallback-Pfad.
- Ein falscher JSON-Typ setzt nur noch das betroffene Config-Feld auf seinen Default
  und meldet dessen Pfad; gültige Nachbarwerte bleiben erhalten. VAD-Werte werden
  beim Laden und Speichern auf endliche, konsistente Grenzen geprüft, sodass auch
  negatives Padding keinen Absturz mehr auslösen kann.
- Der Live-Pegel besitzt jetzt eine echte Synchronisationsgrenze zwischen Audio- und
  Main-Thread. Ein vom CLI-Aufruf selbst gestarteter Whisper-Server wird beim Ende
  garantiert beendet; bereits fremd laufende Server bleiben unangetastet.

### Geändert

- Kritische Lifecycle-, Netzwerkstream- und Dateifehlerpfade haben injizierbare,
  deterministische Testgrenzen. Der ungenutzte zweite WAV-Decoder wurde entfernt;
  Tests prüfen stattdessen direkt das tatsächlich gespeicherte Upload-Format.

## [0.8.9] — 2026-07-21

### Behoben

- Start- und Stoppton liegen jetzt vollständig außerhalb der Mikrofonaufnahme.
  Zuvor überschritten beide eigenen Töne die Spracherkennungsschwelle und konnten
  besonders über ein iPhone-Mikrofon als scheinbare Sprache an Whisper gelangen
  und die eigentliche Transkription mit Untertitel-Floskeln verfälschen.
- Die Bereinigung darf keine Wörter mehr ergänzen, ersetzen oder umstellen. Eine
  neue Worttreue-Prüfung verwirft solche Modellausgaben zugunsten des Rohtexts;
  der Prompt erlaubt keine vermeintlichen Rechtschreib- oder Verhörerkorrekturen
  mehr.

### Hinweis

- 0.8.9 ist die erste öffentlich veröffentlichte Version mit Sparkle. Installationen
  von 0.8.4 müssen dieses Update einmalig manuell per DMG installieren; danach sind
  signierte automatische Updates verfügbar.

## [0.8.8] — 2026-07-21

### Behoben

- Nach dem Speichern beliebiger Einstellungen blieb der globale Aufnahme-Hotkey
  nicht mehr unregistriert. Der alte Carbon-Hotkey wird jetzt ausdrücklich vor dem
  neuen freigegeben; ein echter Registrierungskonflikt wird sichtbar gemeldet.

## [0.8.7] — 2026-07-21

### Hinzugefügt

- Im Aufnahme-Tab lässt sich das Mikrofon direkt auswählen. Neben eingebauten und
  USB-Geräten stehen auch per Integrationskamera verbundene iPhones zur Verfügung;
  die Liste kann bei geöffneten Einstellungen aktualisiert werden.
- „Systemstandard“ bleibt der rückwärtskompatible Default und folgt weiterhin der
  macOS-Auswahl. Ein verschwundenes ausdrücklich gewähltes Gerät erzeugt eine klare
  Fehlermeldung, statt unbemerkt von einem anderen Mikrofon aufzunehmen.

## [0.8.6] — 2026-07-17

### Hinzugefügt

- Die vollständige Anwendung ist jetzt auf Deutsch und Englisch lokalisiert:
  Menü, Einstellungen, Verlauf, Overlay, Modell-Download, nutzernahe Core-Fehler
  und CLI-Diagnosen folgen der von macOS gewählten Sprache.
- Auch der macOS-Mikrofon-Berechtigungsdialog hat eine deutsche und englische
  Beschreibung. Das manuell gebaute App-Bundle verpackt beide Sprachen für GUI
  und eingebettete CLI.
- Das englische README zeigt erstmals durchgehend englische Screenshots. Die Bilder
  stammen aus isolierten Testdaten; der deutsche Verlaufsscreenshot enthält
  ebenfalls keine private Netzwerkadresse mehr.

### Geändert

- Lange englische Hilfetexte und Modellpfade bleiben innerhalb der
  Einstellungsfensterbreite. Zahlenfelder verwenden die zur App-Sprache passende
  Dezimalschreibweise.

## [0.8.5] — 2026-07-16

### Hinzugefügt

- Sparkle 2 prüft automatisch auf signierte Updates. Der neue Menüpunkt „Nach
  Updates suchen …“ startet eine sofortige Prüfung; Installation und Neustart
  erfolgen nur nach ausdrücklicher Zustimmung.
- Update-DMG und Appcast werden mit einem projektspezifischen Ed25519-Schlüssel
  geprüft. Der Feed selbst ist ebenfalls signiert, bevor Sparkle Release Notes
  oder Download-Links vertraut.
- Ein GitHub-Actions-Workflow erzeugt den Appcast aus dem notarisierten DMG eines
  veröffentlichten Releases und stellt ihn über GitHub Pages bereit.
- Einmaliger Bootstrap-Hinweis: 0.8.4 enthält noch keinen Updater. Deshalb muss
  0.8.5 wie bisher manuell per DMG installiert werden; automatische Updates greifen
  erst für spätere Versionen aus einer bereits Sparkle-fähigen App heraus.

### Datenschutz

- Sparkles anonymes Systemprofiling ist explizit deaktiviert. Update-Prüfungen
  übertragen keine Hardware- oder Speicherangaben.

## [0.8.4] — 2026-07-16

### Geändert

- Die Installationsanleitung beginnt jetzt mit einem kurzen Schnellstart:
  Homebrew, whisper.cpp, Ollama, Bereinigungsmodell und das fertige DMG.
- Die READMEs unterscheiden klar zwischen Spracherkennungsprogramm,
  Whisper-Sprachmodell, Ollama und Bereinigungsmodell. Ausführliche Konfiguration,
  Netzwerkbetrieb, CLI und Selbstbau stehen erst nach dem normalen Installationsweg.
- Systemgrenzen sind präzisiert: Das fertige App-Paket ist für Apple Silicon ab
  macOS 13 gebaut; die aktuelle lokale Ollama-Version benötigt macOS 14.

## [0.8.3] — 2026-07-16

### Geändert
- Deployment-Target von macOS 14 auf macOS 13 (Ventura) abgesenkt. Der einzige
  Sonoma-Blocker war eine `onChange`-Signatur in den Einstellungen; die echte
  Untergrenze setzen SMAppService (Login-Item) und die Settings-Form-APIs.

## [0.8.2] — 2026-07-16

### Hinzugefügt

- Stille Post hat ein eigenes App-Icon: eine Sprechblase mit Schallwelle. Sichtbar
  wird es überall dort, wo bisher der graue Platzhalter stand — im Modell-Dialog, in
  den Systemeinstellungen unter „Anmeldeobjekte“ und im Finder. Als Menüleisten-App
  ohne Dock-Symbol bleibt es sonst unauffällig.
- Kleine Größen haben eine eigene, gröbere Zeichnung (`Resources/icon/`): die fünf
  feinen Wellenbalken der Vollversion verschmelzen bei 16 und 32 px zu einem Fleck,
  drei dickere Balken mit breiteren Lücken bleiben getrennt. Ab 64 px ist die volle
  Zeichnung sichtbar besser; die Grenze ist ausgemessen, nicht geschätzt.
- `scripts/build-icon.sh` erzeugt aus den SVG-Quellen das `Resources/AppIcon.icns`.
  Das Ergebnis liegt im Repo, damit `scripts/build-app.sh` weiterhin ohne
  `rsvg-convert` auskommt — das Skript braucht nur, wer die Zeichnung ändert.

## [0.8.1] — 2026-07-16

### Geändert

- Der Schalter „Beim Anmelden starten“ aus 0.8.0 ist am Bildschirm geprüft und die
  Registrierung systemseitig unabhängig bestätigt. Der Versions-Bump war bewusst bis
  zur Verifikation zurückgehalten worden — der Code selbst ist unverändert (`e4f5c90`).

## [0.8.0] — 2026-07-15

### Hinzugefügt

- Stille Post beschafft das Whisper-Modell selbst. Fehlt es beim Start, fragt die App
  und lädt es mit Fortschrittsbalken; abgebrochene Downloads setzen fort statt neu zu
  beginnen. Bewusst eine Frage: 1,6 GB zieht man niemandem ungefragt übers Netz.
- „Beim Anmelden starten“ in den Einstellungen unter „Allgemein“. Der Zustand liegt
  bewusst nicht in `config.json`, sondern kommt von `SMAppService` — sonst könnten
  App-Konfiguration und Systemeinstellung auseinanderlaufen (`48725fb`).
- `stillepost-cli install-model [modell] [--force]` als skriptbarer Weg: stdout
  enthält nur den Pfad, der Fortschritt geht nach stderr.

### Geändert

- `doctor` unterscheidet jetzt eigene Kopie, geliehenen Verweis und fehlendes Modell.
  Ein Verweis in einen fremden Cache funktioniert heute, aber das Modell gehört Stille
  Post dann nicht — räumt das andere Programm auf, ist es weg.
- Angeboten werden bewusst nur `large-v3-turbo` (Standard) und `large-v3`. Kleinere
  Modelle gibt es nicht: schlechtere Erkennung will niemand.
- Beide READMEs auf den neuen Installationsweg gezogen; der dokumentierte CLI-Pfad
  war vorher für niemanden lauffähig, weil die Binary im App-Bundle steckt und nicht
  im PATH liegt (`b307795`).

Vollständige Fassung: `2bbca07`.

## [0.7.3] — 2026-07-15

### Behoben

- `install-model.sh` prüfte mit `[ -f ]`, ob das Modell da ist. Das folgt Symlinks und
  meldete auch dann „schon da“, wenn dort nur ein Verweis auf einen fremden Cache lag —
  das Skript hat nie geladen. Zusätzlich setzen abgebrochene Downloads jetzt fort
  (`9c29580`).

## [0.7.2] — 2026-07-15

### Behoben

- Rund jedes dritte Diktat endete auf der erfundenen Floskel „Vielen Dank“. Ursache war
  der Tastenklick beim Stoppen: Ein einzelner Frame über der Pegelgrenze ließ ein fast
  leeres Segment als Sprache gelten, und auf Stille erfindet Whisper zuverlässig
  Floskeln. Sprache wird jetzt aufsummiert gemessen (`minSpeechSec`, Default 0,15 s)
  statt geflaggt.
- Stille wird bei jedem Schließgrund auf `paddingSec` gekürzt, auch am Segmentanfang —
  für sich korrekt, aber nachweislich nicht die Ursache der Floskeln.

Messwerte und der verworfene Verdacht: `e4ada28`.

## [0.7.1] — 2026-07-15

### Geändert

- Der Hotkey wird per Tastendruck aufgenommen, statt den virtuellen Carbon-Keycode als
  Zahl einzutippen. Kombinationen ohne Cmd/Opt/Ctrl werden abgelehnt, weil ein global
  registrierter Hotkey auf einer nackten Taste sie systemweit blockieren würde.
- Der angezeigte Tastenname kommt aus dem aktiven Tastaturlayout statt aus einer fest
  verdrahteten ANSI-Tabelle: Keycodes sind physische Positionen, und Keycode 6 liegt
  auf einer deutschen Tastatur auf „Y“, nicht auf „Z“ (`c073459`).

## [0.7.0] — 2026-07-15

### Hinzugefügt

- Wie lange das Bereinigungs-Modell nach dem Diktat geladen bleibt, ist als
  `keepAlive` pro Endpoint einstellbar — Config-Feld und Dropdown im Bereinigungs-Tab.

### Geändert

- Der Default wechselt von „dauerhaft“ auf 2 h. Das Modell wird ohnehin beim
  Aufnahme-Start vorgewärmt und lädt, während man spricht; der Dauer-Pin kostete
  durchgehend Speicher, ohne im Alltag viel zu retten (`d83a22a`).

## [0.6.2] — 2026-07-11

### Hinzugefügt

- Erstveröffentlichung: lokale Whisper-Spracherkennung, ehrliche LLM-Textbereinigung
  (putzt, formuliert nie um), globaler Hotkey, Menüleisten-App, Endpoint-Fallback-Kette,
  Einstellungs-GUI, Verlauf mit Diagnose und Headless-CLI (`99a8547`).

Die Versionen vor 0.6.2 liegen nicht im veröffentlichten Verlauf — die
Erstveröffentlichung trug bereits diese Nummer.
