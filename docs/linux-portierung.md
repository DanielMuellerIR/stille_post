# Linux-Portierung: lokales Diktat unter CachyOS und Linux Mint

Stand: 2026-11-04. **Ursprünglicher Umsetzungsplan.** Eine erste installierbare
Fassung ist inzwischen vorhanden; aktueller Umfang und offene Abnahme stehen in
[Linux-Nutzung und Grenzen](linux.md). Grundlage ist
Quellstand `dd9169c` / Version `0.9.46`. Offene Arbeit wird in
[backlog.md](../backlog.md) geführt; dieses Dokument beschreibt die Umsetzung.

## Ziel und Entscheidung

Stille Post soll auf einem CachyOS/KDE/Wayland-Arbeitsplatz und einem
Linux-Mint/Cinnamon/X11-Rechner diktieren können. Aufnahme und Whisper laufen
auf dem jeweiligen Linux-Rechner. Zur Bereinigung geht ausschließlich der fertig
zusammengefügte Text zum konfigurierten Mac-Dienst. Ist dieser nicht erreichbar,
übernimmt ein lokales Bereinigungsmodell; scheitert auch das, bleibt der
deterministisch nachbearbeitete Rohtext verfügbar. Updates werden automatisch
auf GitHub gefunden und wie beim Vorbild Mucke, Baby! nach Zustimmung installiert.

**Empfehlung:** Swift-Kern erhalten, Plattformadapter herauslösen und eine dünne
Qt-6-Oberfläche für Linux ergänzen. Zuerst einen lauffähigen CLI-Durchstich und
die Hardwaremessung herstellen. Erst nach diesem Entscheidungstor die GUI und
den Updater fertig bauen. Eine vollständige Neuentwicklung der Bereinigungslogik
wäre wegen ihrer zahlreichen Fehler- und Datenschutzverträge unnötig riskant.

## Was geprüft ist und was noch offen bleibt

| Bereich | Befund / Beleg | Konsequenz |
|---|---|---|
| Repository | `Package.swift` bindet Sparkle ein; AppKit/SwiftUI/Carbon bilden die GUI; auch der Kern importiert Apple-Frameworks. CI läuft bisher auf macOS. | Keine durch bloßes Neubauen erhältliche Linux-App. |
| GitHub-Auslieferung | Die bei der Bestandsprüfung betrachteten letzten zehn Releases, einschließlich `v0.9.46`, enthalten DMG-/Prüfsummenartefakte. | Kein Linux-Installationsartefakt in diesem geprüften Bestand; kein Anspruch, sämtliche fremden Forks ausgeschlossen zu haben. |
| CachyOS-Ziel | Am Planstand geprüft: CachyOS, KDE, Wayland, Ryzen 9 7945HX, 32 Threads, etwa 31 GiB sichtbarer RAM und Radeon RX 7600M XT. `swift` und `ollama` sind im aktuellen PATH nicht vorhanden. | Build-Toolchain und lokale Modelle müssen eingerichtet werden; GPU-Beschleunigung ist noch nicht gemessen. |
| Mint-Ziel | Am Planstand geprüft: Linux Mint 22.2, Cinnamon/X11, Ryzen 7 7730U, 8 Kerne/16 Threads, etwa 29 GiB sichtbarer RAM, kein Swap; `ollama` und `whisper-server` fehlen im geprüften PATH. Dokumentierte Ausstattung: Vega-8-iGPU, lüfterloser Rechner mit Serveraufgaben. | Kurze, begrenzte Tests; CPU-Basis und thermische Grenzen zuerst bestimmen. GPU-Treiber und realer Mikrofonpfad sind noch ungetestet. |
| Mac-Bereinigung | Gewünschte Topologie ist der bestehende leistungsstarke Mac als Primärdienst, wie beim bisherigen Mac-Client. Historische Einrichtungsnotizen enthalten ältere Modelle. | Aktuelle laufende Konfiguration vor Übernahme gezielt prüfen; Quelltext/Projektregeln schlagen historische Notizen. |
| Update-Vorbild | `mucke_baby/Sources/UpdaterController.swift` und `docs/sparkle-release.md` verwenden Sparkle, signierte GitHub-Artefakte und einen Pages-Feed. | Das Bedien- und Vertrauensmodell ist übertragbar, Sparkles macOS-Implementierung nicht. |

Namen, Adressen, Benutzerkonten, Schlüsselmaterial und persönliche
Verzeichnisnamen gehören ausschließlich in die lokale Einrichtung.
`CLEANUP_PRIMARY_URL` bezeichnet nachfolgend
einen lokal einzutragenden Endpunkt, keine bereits implementierte neue
Umgebungsvariable. Der Plan enthält keine Aussage, dass eine Linux-Pipeline oder
ein Linux-Update bereits erfolgreich gelaufen sei.

## Architektur und Wiederverwendung

```text
Qt-Oberfläche + Linux-Desktopadapter
  Mikrofon → PCM → privater lokaler Kanal → Swift-Diktierkern
  Hotkey / Status / Verlauf / Clipboard           │
                                                ├─ VAD → lokaler whisper-server
                                                └─ Gesamttext → Cleanup-Kette
                                                                │
                                     Mac-Textdienst → lokales LLM → Rohtext
```

Swift ist unter Linux verfügbar, einschließlich offizieller Container. Damit ist
die Sprache kein Ausschlussgrund; das macht Apple-Frameworks und bestehende
Netzwerkimplementierungen noch nicht portabel.
[Swift: Linux-Installation](https://www.swift.org/install/linux/)

### Bausteine und konkrete Schnittstellen

| Bestand | Linux-Arbeit |
|---|---|
| `DictationEngine`, `DictationRequestStore`, `RecordingAudioSession`, `WavCodec`, `VadSegmenter`, Text-/Verlaufspolitik | Algorithmen und Tests gemeinsam halten. Plattformtypen an den Rändern entfernen; kein zweiter Cleanup-Algorithmus in der GUI. |
| `DictationDependencies` | Vorhandene Recorder-/Segmenter-/Transcriber-/Cleanup-Protokolle als Trennstelle nutzen. `live(config:)` und Apple-spezifische Extensions in Plattformmodule verlagern. |
| `AudioRecorder`, `AudioInputDevice`, `AudioDecoder` | AVFoundation/CoreAudio durch Linux-Aufnahme und Decoder ersetzen. Qt nimmt PCM entgegen; kontrollierte Resampling-Stufe liefert 16 kHz mono Float32 an den Kern. Dateiformate über einen gepinnten lokalen Decoder, beispielsweise FFmpeg; Ressourcen- und Laufzeitgrenzen behalten. |
| `CleanupTransport`, `WhisperClient` | `FoundationNetworking` und Linux-HTTP-Verhalten prüfen. `CFNetwork`, `URLSession.AsyncBytes`/`bytes(for:)`, Proxybehandlung, Redirects, Streaming-Framing und Timeouts nicht als kompatibel voraussetzen. Falls nötig Linux-Transport hinter demselben Protokoll mit `URLSessionDataDelegate` oder gepflegter HTTP-Bibliothek bauen. |
| `CleanupNetworkPolicy`, `ModelInstaller`, Dateizugriffe | Darwin/Glibc-Imports, Dateirechte, atomare Ersetzung und Prozesssignale portieren. `ConfigFile` und `HistoryStore` zeigen bereits bedingte Darwin/Glibc-Imports, sind aber weiterhin zu prüfen. |
| `CleanupService`, `KeychainUpsert` | Schlüsselzugriff aus der Bereinigungslogik in einen injizierbaren Secret-Store ziehen. Linux: Secret Service, ersatzweise vorhandener Environment-Pfad. |
| `SileroModel` | CoreML ist ein eigener Apple-Adapter. Erste Linux-Stufe nutzt vorhandenes RMS-VAD; Silero erfordert später einen separaten Backend-/Modellvertrag und Vergleichseval. Keine stille Umdeutung einer importierten Silero-Einstellung. |
| `PasteboardSnapshot`, Hotkey, App-Erkennung, Overlay | Linux-Adapter mit ausdrücklich gemeldeten Fähigkeiten. macOS-Bundle-IDs sind keine Linux-App-Identitäten; Profilregeln brauchen einen Plattformbezug. |
| `BridgeServer`, `BridgeIdentity` | Network/Security/SystemConfiguration separat halten. Die iOS-Empfängerbrücke gehört nicht zum ersten Linux-Umfang. Linux-UI bietet sie zunächst nicht als funktionsfähig an. |
| `Config`, Ressourcen, CLI | Homebrew-/Library-Pfade durch Linux-Vorgaben ersetzen, Ressourcenauffindung im installierten Paket testen, CLI-Befehle und deutsche/englische Texte erhalten. |

`Package.swift` muss die macOS-GUI und die Sparkle-Abhängigkeit auf macOS
begrenzen. Linux baut nur portable Kernteile, Linuxadapter und CLI/Worker.
Mac-Adapter bleiben separat testbar; `Tests/` bleibt erhalten. Ein unspezifisches
`#if os(Linux)` um ganze Funktionen darf keine Sicherheitsprüfung wegschneiden.

Für die GUI wird **Qt 6 mit C++** als Arbeitshypothese gewählt: Fenster, Tray,
Audio, Clipboard und D-Bus liegen in einem Stack. Der Swift-Kern läuft als
Kindprozess mit vererbten privaten Pipes: versioniertes, längenbegrenztes
Steuerprotokoll, eigener binärer PCM-Kanal, Ereignisse für Status und Ergebnis.
Keine öffentlich lauschende GUI-HTTP-Schnittstelle; keine Diktate oder Secrets
in Prozessargumenten. Begrenzte Puffer, Backpressure, Abbruch bei Elternprozessende
und eine einzige aktive Aufnahme sind Teil des Protokolls. Der CLI-Worker muss
auch ohne GUI testbar sein.

Qt stellt Audioeingabe und Clipboard-APIs bereit; Paketierung und tatsächliche
Desktopintegration bleiben separat nachzuweisen.
[QAudioSource](https://doc.qt.io/qt-6/qaudiosource.html),
[QClipboard](https://doc.qt.io/qt-6/qclipboard.html),
[Qt-Linux-Auslieferung](https://doc.qt.io/qt-6/linux-deployment.html)

Alternativen für das erste Entscheidungstor:

- **Swift + GTK direkt:** eine Sprache weniger an der App-Grenze, dafür zusätzliche
  Swift-/GTK-Bindings und mehr Linux-Integrationsarbeit; nur vorziehen, wenn der
  Prototyp nachweislich einfacher zu paketieren und zu warten ist.
- **Tauri/Rust + Swift-Worker:** kann eine vorhandene Updater-Lösung attraktiv
  machen, bringt aber Webview, JS und eine weitere Sprache hinzu. Für die kleine
  Diktieroberfläche zunächst kein ausreichender Gewinn.
- **Kompletter Rust-/C++-Rewrite:** erst prüfen, falls der gemeinsame Swift-Kern
  am nachgewiesenen Runtime-/Deployment-Aufwand scheitert. Dann zunächst
  gemeinsame sprachunabhängige Vertrags-Fixtures exportieren, nicht Verhalten
  aus der Erinnerung nachbauen.

## Aufnahme und lokale Modelle

### Whisper

`large-v3-turbo` und der vorhandene `whisper-server`-HTTP-Vertrag bleiben gesetzt.
Whisper.cpp dokumentiert Linux, CPU und Vulkan; das belegt mögliche Backends,
keine garantierte Latenz oder Stabilität auf den konkreten Geräten.
[whisper.cpp](https://github.com/ggml-org/whisper.cpp)

Auf CachyOS zuerst CPU und Vulkan auf der dedizierten Radeon gegeneinander
messen. Auf Mint ist CPU die verlässliche Ausgangshypothese; der dokumentierte
kleine iGPU-Speicher ist kein Nachweis, dass Modell und Arbeitsbereich dort
vollständig oder schneller laufen. Vulkan erst ergänzen, wenn der konkrete
Treiber-/Speicherpfad bestanden hat. ROCm ist keine Voraussetzung dieses Ports.
App, Whisper, lokale Bereinigung und andere Desktopprogramme müssen gemeinsam
in den verfügbaren RAM/VRAM passen; Modelldateigröße ist nicht Spitzenverbrauch.

Ein CPU-Build bleibt als funktionaler Rückfall erhalten. Ein Wechsel von GPU
auf CPU nach einem Fehler darf höchstens einen kontrollierten lokalen
Wiederholungsversuch auslösen und kein Teilergebnis doppelt übernehmen. Keine
automatische Verkleinerung oder Quantisierung des Whisper-Modells. Wenn Mint die
Latenzgrenze verfehlt, ist das ein Produktentscheid mit Messbeleg, kein Anlass,
Audio an den Mac auszulagern.

Whisper wird nur an eine explizite Loopback-Adresse gebunden. Der vorhandene
`WhisperEndpoint`-Vertrag bleibt einschließlich Verbot von DNS-Namen, Proxys und
Redirects im Audiotransport erhalten. Nur der selbst gestartete Server darf von
der App beendet werden; vorhandene Server bleiben bestehen. Modell-/Binary-
Download und Mikrofonaufnahme sind getrennte Vorgänge.

### Aufnahme und Messprogramm

Geräte-ID, Systemstandard, Eingangspegel, Hotplug und Fehler werden sichtbar.
USB-Geräteverlust, Suspend/Resume und ein Wechsel der Desktop-Audiositzung
müssen sauber abbrechen oder nachvollziehbar wiederaufnehmen. Mikrofon ist nur
während einer Aufnahme offen. Für den ersten CLI-Spike darf `pw-record` helfen;
ein Shell-Prozess mit beliebigen Audioargumenten ist keine fertige GUI-Integration.

Synthetisches deutsches Referenzaudio mit 10/30/120 Sekunden, Fachwortliste,
Pausen, mehreren Segmenten und Stille auswerten. Dieselben Dateien und
Modellprüfsummen auf beiden Linux-Zielen und auf einem Mac verwenden. Festhalten:
Zeiten für Modellstart, erstes Segment, Segmenttranskription, Restarbeit nach
Stopp und Cleanup; WER/CER beziehungsweise bestehende Qualitätsmetriken;
Spitzen-RSS/VRAM, CPU/GPU-Auslastung und thermisches Verhalten. Deutsch fest
einstellen, nicht `language=auto`.

Vorgeschlagene Abnahmegrenze für den regulären STT-Betrieb: warm mindestens
Echtzeitfähigkeit (Verarbeitungszeit/Audiodauer unter 1) ohne wachsenden Rückstau
und höchstens drei Sekunden STT-Restarbeit nach einem 30-Sekunden-Diktat. Das
sind Ziele, keine gemessenen Zusagen; Primär-Cleanup, lokaler Fallback und
Kaltstart werden separat ausgewiesen. Auf dem lüfterlosen Mint-Gerät zusätzlich
ein begrenzter Wiederholungslauf bei normaler Serverlast; keine mehrstündige
unbeaufsichtigte Lastprobe. Zielverfehlung vor GUI-Vollausbau entscheiden.

## Textbereinigung: Mac zuerst, lokal als Rückfall

Die Linux-Konfiguration soll explizit diese Reihenfolge anbieten:

1. Konfigurierter Mac-Ollama-Endpunkt (`CLEANUP_PRIMARY_URL`).
2. Ollama auf explizitem lokalem Loopback, mit demselben freigegebenen Modell.
3. Rohtext mit `TranscriptPolish.repairPunctuation`, wenn kein Dienst liefert.

Die konkrete Adresse wird lokal eingerichtet; keine privaten Standardwerte im
Produkt und kein zusätzlicher Cloud-Dienst ohne Nutzerkonfiguration. Ein
vorhandener „nur lokal“-Modus überspringt sämtliche Nicht-Loopback-Endpunkte,
einschließlich des Macs. Standardmodell laut aktuellem Quelltext ist
`gemma4:e4b-it-qat`; `think: false` und `num_ctx: 16384` gelten für Chat und
Warm-up gleichermaßen. Primär `keep_alive: 2h`, Fallback `30m`; periodisches
Warm-up ausschließlich bei ausdrücklich gewähltem `-1`.

Die Bereinigung bleibt **ein logischer Aufruf je Gesamtdiktat**; darin dürfen die
vertraglichen Transportwiederholungen stattfinden. Kein Cleanup je VAD-Segment,
keine parallelen oder gehedgten Endpunktanfragen. Die nachfolgende Unterscheidung
ist im gegenwärtigen `CleanupService` tatsächlich vorhanden und beim Port zu
erhalten:

- Bei kürzlich nachgewiesener Erreichbarkeit startet der primäre Ollama-Endpunkt
  direkt als Stream. Ein Verbindungs-/Provider-/Framefehler erhält genau einen
  neuen Streamversuch mit frischer Sitzung.
- Bei zehn Sekunden Leerlauf entscheidet eine kurze Erreichbarkeitsprobe:
  erreichbar → geduldige nicht-streamende Wiederholung; unerreichbar → nächster
  Endpunkt. „Geduldig“ bedeutet keine endlose Anfrage: Gesamtbudget und
  Nutzerabbruch bleiben wirksam.
- Ohne frischen Erreichbarkeitsbeleg sowie bei Fallback-Endpunkten verwendet der
  aktuelle Code zuerst eine schnelle Probe und danach eine nicht-streamende
  Anfrage. Diese bestehende Kaltstartverzweigung nicht versehentlich entfernen.
- Netzwerk-/Dienstfehler wechseln den Endpunkt. Plausibilitätsfehler liefern
  Rohtext mit deterministischer Nachstufe und lösen keinen weiteren Dienst aus.
  Worttreue, Längenkorridor und Reparatur einzelner Satzteile bleiben identisch.
- Nutzerabbruch ist kein Dienstausfall: keine neue Anfrage, kein Fallback und
  keine verspätete Ergebnisübernahme.

Ollama dokumentiert AMD-/Vulkan-Pfade, aber die Verfügbarkeit eines Backends
beweist weder den tatsächlichen Modellbetrieb noch ausreichenden Speicher auf
diesen Rechnern. Den lokalen Fallback deshalb auf beiden Zielen real laden,
kalt/warm messen und zusammen mit dem laufenden Whisper testen. Auf Mint ist
langsame CPU-Bereinigung zunächst ein bewusst sichtbarer Notbetrieb; kann sie
das vereinbarte Zeit-/Speicherbudget nicht erfüllen, bleibt Rohtext verfügbar.
Das erfüllt allein noch nicht das Ziel „lokaler Modellfallback auf beiden
Geräten“: Dieser Teil der Abnahme bleibt dann offen. Die Oberfläche unterscheidet
erfolgreiche lokale Modellbereinigung, langsamen lokalen Notbetrieb und reinen
Rohtext-Rückfall. Der Konflikt zwischen lokaler Inferenz und begrenzter Last auf
dem lüfterlosen Server ist im ersten Entscheidungstor aufzulösen; kein
Dauerladen und kein zusätzlicher periodischer Warm-up des lokalen Fallbacks.
Ein kleineres Bereinigungsmodell braucht den bestehenden Qualitätstest und eine
ausdrückliche evidenzbasierte Modellentscheidung.
[Ollama-Hardwareunterstützung](https://docs.ollama.com/gpu)

Der Mac-Dienst braucht einen nachweislich erreichbaren, begrenzten Zugangsweg.
Für die Umsetzung vorhandene LAN-/VPN-/Tunnel-Konfiguration prüfen und den
kleinsten passenden Weg wiederverwenden. Keine ungeschützte öffentliche
Ollama-Freigabe. Authentifizierung, TLS-Vertrauen und Redirectbehandlung mit
synthetischem Text prüfen. Ein Verbindungsversuch allein beweist noch keinen
funktionierenden Streaming-Chat. Linux-Clients dürfen keinen fremden Mac-Dienst
eigenmächtig umkonfigurieren.

## Desktop: Wayland und X11 getrennt abnehmen

| Funktion | KDE/Wayland | Cinnamon/X11 |
|---|---|---|
| Globaler Hotkey | XDG-GlobalShortcuts-Portal mit Laufzeitprüfung, Nutzerfreigabe und registriertem Ergebnis. | Portal verwenden, wenn verfügbar; sonst X11-Key-Grab als separater Adapter. |
| Gedrückthalten | Aktivierungs-/Deaktivierungssignale prüfen; bei fehlendem Loslassen sicher stoppen. | KeyPress/KeyRelease mit Autorepeat-Filter; Modifier und Tastaturlayout testen. |
| Clipboard | Qt plus reale Compositor-Prüfung; Hintergrundzugriff/Ownership nicht voraussetzen. | Qt-Clipboard mit laufender Ereignisschleife; PRIMARY und CLIPBOARD unterscheiden. |
| Einfügen | Optionaler, ausdrücklich freigegebener RemoteDesktop-Portalpfad erst nach Test; ohne verlässlichen Pfad kopieren und manuelles Einfügen anzeigen. | XTest/Ctrl+V nur bei sicher bekanntem Ziel und nach Loslassen des Hotkeys. Terminalsonderfall nicht blind mit Ctrl+V behandeln. |
| Ziel-App/Profile | Unter Wayland keine allgemeine Abfrage fremder aktiver Fenster voraussetzen; bei unbekanntem Ziel neutrale Regeln/manuelle Auswahl. | Fensterkennung beobachten, aber Zielwechsel und Passwortfelder weiterhin konservativ behandeln. |

Das GlobalShortcuts-Portal definiert gebundene Sitzungen und Aktivierungs- sowie
Deaktivierungssignale. Daraus folgt keine automatische Unterstützung jeder
installierten Desktopversion. Ein normaler Qt-Fenster-Shortcut ersetzt keinen
globalen Shortcut.
[GlobalShortcuts-Portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)

Hotkeys und Einfügen sind unterschiedliche Berechtigungen. Das
RemoteDesktop-Portal stellt einen kontrollierten Eingabepfad bereit; der
Clipboard-Portalzugriff ist an dessen Sitzung gekoppelt. Kein allgemeines
stilles Tastatureinspritzen unter Wayland versprechen. Der Port darf weder einen
Root-Daemon noch breiten `/dev/uinput`-Zugriff als Standardinstallation verlangen.
Ist automatische Eingabe im gewählten Desktop nicht verlässlich möglich,
gehört „kopiert — jetzt einfügen“ zur ausdrücklich sichtbaren Produktgrenze.
[RemoteDesktop-Portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html),
[Clipboard-Portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Clipboard.html)

Das Overlay darf den ursprünglichen Eingabefokus nicht stehlen. Clipboard-
Wiederherstellung nur nach nachgewiesenem erfolgreichem automatischem Einfügen
und unverändertem Clipboard-Besitz. Bei Screen-Sharing-/Remote-Viewern, unbekanntem
Ziel oder manuellem Einfügen bleibt das Diktat in der Zwischenablage. Tests mit
Browser, Texteditor, Terminal, XWayland-Anwendung, offenem Remote-Viewer,
Layoutwechsel, gesperrter Sitzung und abgelehnten Portalberechtigungen gehören
zur Abnahme. Xvfb ersetzt keine echte Wayland-Sitzung.

Falls der Desktop das Hotkey-Portal nicht anbietet, darf eine dokumentierte
Desktop-Tastenkombination ein eng begrenztes `stillepost-cli toggle` auslösen.
Für diesen Pfad nur einen benutzergebundenen IPC-Kanal mit festen Kommandos
vorsehen, keine Shell-Auswertung. Gedrückthalten ist damit nicht automatisch
verfügbar. Tray und Aufnahme-Schaltfläche bleiben als sichtbare Einstiege.

## Daten, Secrets und Betrieb

- Konfiguration unter `$XDG_CONFIG_HOME/stillepost`, persistente Daten/Modelle
  unter `$XDG_DATA_HOME/stillepost`, Logs unter `$XDG_STATE_HOME/stillepost`,
  flüchtige Steuerkanäle unter `$XDG_RUNTIME_DIR`; die üblichen XDG-Defaults
  verwenden, wenn Variablen fehlen. Keine automatisch synchronisierten
  Verzeichnisse für Audio, Schlüssel oder Verlauf.
- Benutzerverzeichnisse privat, sensible Dateien nur für den Benutzer lesbar.
  Temporäre WAV-Dateien nach Erfolg löschen, nach jedem Fehler zur Diagnose
  erhalten. Abgebrochene Sitzungen und Decoderfehler ausdrücklich testen.
- Secret Service über D-Bus asynchron ansprechen. Verfügbarkeit/Entsperrung auf
  beiden Desktops prüfen; bei Fehlen kein Klartext-Fallback. Environment bleibt
  eine explizite Alternative, Secrets werden weder geloggt noch als Argumente
  übergeben. Die API ist standardisiert, ein laufender Dienst damit nicht
  garantiert.
  [Secret-Service-Spezifikation](https://specifications.freedesktop.org/secret-service/latest/)
- Konfigurationsimport vom Mac als geprüfte Kopie: relative Plattformpfade,
  Linux-Gerätekennungen und Secret-Verweise neu zuordnen. Keine unveränderte
  Übernahme von Homebrew-Pfaden, Bundle-IDs oder Schlüsselbundinhalten.
- Autostart ist freiwillig und sitzungsgebunden. Keine globale Wachhaltung,
  kein root-Service, kein automatisches Aktivieren der Netzwerk-Brücke.
- Diagnose zeigt Backend, Versionen, Zustand und anonymisierte Timings, keine
  vollständigen Diktate, Tokens oder privaten Endpunktadressen in exportierten
  Berichten. Unter Linux auch geerbte Proxyvariablen gezielt in Negativtests
  einbeziehen.

## Auslieferung und GitHub-Updates

Sparkle ist ein macOS-Framework. Übernommen werden vom Vorbild: automatische
Suche, manueller Menüeintrag, Zustimmung zur Installation, signierte Artefakte,
unveränderliche Releases und Schlüssel außerhalb des Repositories.
[Sparkle](https://sparkle-project.org/)

**Erste Auslieferungsform:** benutzerlokales, versioniertes AppDir-Bundle als
Archiv; zusätzlich AppImage aus derselben Nutzlast, wenn der Packaging-Spike auf
beiden Zielen besteht. Das AppDir ist zugleich der Rückfall ohne FUSE. Swift-
Runtime, Qt-Plugins für Wayland/X11, lokale Hilfsprogramme und Lizenzen sind
Bestandteil der geprüften Nutzlast; GPU-Treiber bleiben Systembestandteil.
Whisper-/LLM-Modelle bleiben getrennte, wiederverwendbare Downloads mit
Integritätsprüfung und verständlicher Größenanzeige.
[AppImage-AppDir-Aufbau](https://docs.appimage.org/packaging-guide/manual.html)

Auf einer festgehaltenen ältesten unterstützten Ubuntu/Mint-kompatiblen Basis
bauen und auf dem realen CachyOS gegenprüfen. Aktuell ist Ubuntu 24.04 der
Startkandidat wegen der dokumentierten Mint-Basis; dies ist keine Zusage für
ältere Mint-Versionen. Toolchain und Container per Version/Digest pinnen.
Portable x86_64-Builds statt `-march=native`; Optimierungen in bewusst getrennten
Backendvarianten. Kein „AppImage läuft überall“-Versprechen.

Der erste Updater lädt Vollpakete. Zsync/AppImageUpdate ist eine spätere
Bandbreitenoptimierung, kein Ersatz für die Vertrauensprüfung.
[AppImageUpdate](https://github.com/AppImageCommunity/AppImageUpdate)

Der Releasevertrag ist vor Implementierung festzuschreiben:

1. Ein Linux-Manifest enthält Produktkennung, Kanal, Architektur, monotone
   Buildnummer, Produktversion, Mindestplattform, Größe, SHA-256, Download-URL
   und Schlüsselkennung. Signatur über exakt definierte Manifestbytes mit
   separatem projektspezifischem Ed25519-Schlüssel; etablierte Kryptobibliothek
   verwenden, keine eigene Kryptografie. Der öffentliche Vertrauensanker wird
   mitgeliefert, der private Schlüssel liegt nur im Release-Secret-Store.
2. GitHub Releases liefert unveränderliche Nutzlasten; ein separat gepflegter
   signierter Linux-Feed auf Pages verweist darauf. Linux ergänzt den bestehenden
   macOS-Appcast. Keine schwache Ableitung des Zielartefakts aus Dateinamensmustern
   oder beliebigen URLs in unvalidiertem JSON.
3. Vor Installation Signatur, Größe, Hash, Architektur, Produkt/Kanal und
   Versionsfortschritt prüfen. Downloads begrenzen; Redirectziele kontrollieren.
   Archivpfade, Symlinks und entpackte Gesamtgröße validieren. Eine öffentliche
   Prüfsummendatei ohne authentischen Vertrauensanker genügt nicht.
4. Herunterladen in Staging, nur bei untätiger App installieren. In ein neues
   Versionsverzeichnis entpacken, installierten Selbsttest starten und den
   aktuellen Verweis atomar wechseln. Keine Aufnahme oder Bereinigung für ein
   Update abbrechen. Ohne Schreibrecht zur manuellen Installation führen, kein
   stilles sudo.
5. Eine vorangegangene geprüfte Version behalten. Startbestätigung und Watchdog
   unterscheiden erfolgreichen Start von Absturz; bei fehlerhaftem neuen Start
   genau einen kontrollierten lokalen Rückfall anbieten/ausführen. Datenmigration
   vorher sichern und rückwärts kompatibel halten. Eine beschädigte Datenmigration
   wird durch Binär-Rollback allein nicht repariert.
6. Ungefragte Netzwerk-Downgrades verhindern. Ein bewusst gewählter lokaler
   Rollback auf das bereits verifizierte Vorgängerpaket ist ein eigener Vorgang.
   Schlüsselrotation braucht einen vom bisherigen Schlüssel authentisierten
   Übergang und einen dokumentierten Wiederherstellungsweg.

CI baut/testet macOS weiter und ergänzt Linux-Kern, Desktopadapter und
Paketprüfung. Release-Jobs verwenden gepinnte Actions, minimale Rechte und
getrennte Signierschritte. Tests für untrusted Pull Requests erhalten keine
Signierschlüssel. Öffentliche Artefakte werden auf private Daten geprüft. Ein
Tag/Release wird erst nach konkretem Veröffentlichungsauftrag erstellt; Linux-
Entwicklung alleine autorisiert keinen GitHub-Push.

## Meilensteine und Abnahme

### 0 — Bestandsaufnahme und technische Entscheidung

Aktuelle Host-/Sitzungs-/Audio-/GPU-/Portalstände erfassen; Mac-Cleanup und
lokalen Fallback mit künstlichem Text prüfen. Swift-Toolchain nur im isolierten
Buildpfad vorbereiten. Ein portabler Kern-Minimalbuild, Linux-Streamingtransport,
Qt-Tray/Audio/Hotkey-Prototyp und relocatierbares Paket werden getestet.

**Ergebnis:** kurze protokollierte Entscheidung für Stack und Paketbasis;
bekannte Desktopgrenzen; reale STT-/Cleanup-Messung auf beiden Zielen. Ein
scheiternder Kern-/Runtime-Spike wird vor dem GUI-Vollausbau entschieden.

### 1 — Gemeinsamer Kern und Linux-CLI

Plattformmodule trennen, Linux-Pfade/Secrets/HTTP ergänzen, Datei-Transkription
und Cleanup mit vorhandener CLI herstellen. Linux-Fixtures und macOS-Tests
laufen gegen denselben Algorithmus.

**Abnahme:** feste deutsche WAV → lokale STT → einmalige Gesamtbereinigung;
bestandskompatibler Verlauf; Abbruch- und Dateiverträge; Netzwerkfehler/
Plausibilitätsfehler sauber unterschieden; keinerlei Audio im Nicht-Loopback-
Traffic. macOS-Build, Tests und Audio-E2E bleiben grün.

### 2 — Benutzbares Diktat auf beiden Desktops

Qt-Oberfläche mit Tray, Status/Abbruch, Aufnahmegerät, Einstellungen, Verlauf,
Kopieren und globalem Toggle. Private Worker-Anbindung, Aufnahme und RMS-VAD
integrieren. Gedrückthalten und automatisches Einfügen nur für bestandene
Adapter freigeben; verbleibende Fähigkeiten sichtbar kennzeichnen.

**Abnahme:** echte Mikrofonaufnahme auf Wayland und X11; Browser/Editor/Terminal;
Hotplug, Suspend, Sperre, Portalablehnung, Zielwechsel und Remote-Viewer.
Kein verlorener Text, kein Fokusdiebstahl und keine fremde Clipboard-
Wiederherstellung. Bestehende Plattform-Testeinstiege sinngemäß für isolierte
Linux-Tests anbieten.

### 3 — Installationspaket und sicherer Updatepfad

Versioniertes Bundle erzeugen, Erstinstallation/Deinstallation ohne root,
optionalen Autostart und signierten Testfeed herstellen. Keine öffentliche
Testveröffentlichung notwendig: lokaler HTTPS-Testfeed oder isolierte
Release-Testumgebung genügt.

**Abnahme:** alte Testversion → neue Testversion → Neustart auf beiden Geräten;
Verlauf/Config/Modelle bleiben erhalten. Manipulierte Signatur, falscher Hash,
Architektur-/Versionsfehler, unterbrochener Download, voller Datenträger,
Abbruch während Staging und fehlgeschlagener Neustart werden kontrolliert
abgefangen. Rückfall auf die geprüfte vorherige Version funktioniert.

### 4 — Pilot und Freigabe

Mehrere Tage realen Diktierbetrieb auf beiden Zielen, getrennte Messwerte für
Mac-Cleanup und lokalen Rückfall. README-Sprachen, Linux-Grenzen und
Installationsanleitung ergänzen. Modelländerungen bleiben eigene Entscheidungen.

**Abnahme:** keine offenen Datenschutz-/Textverlustfehler, akzeptierte Latenz
und Ressourcenlast je Gerät, realer Update-Lauf und macOS-Regressionsprüfung.
Jede vollständig umgesetzte und verifizierte Verhaltensänderung erhält nach
Repo-Konvention ihren Versions-Bump, Changelog-Eintrag, aufgabenbezogenen Commit
und privaten Fleet-Push. Die öffentliche Freigabe folgt erst nach dem Pilot;
ein öffentliches Linux-Release braucht den gesonderten konkreten Auftrag.

## Verbindliche Tests und offene Risiken

| Risiko | Erforderlicher Nachweis |
|---|---|
| Linux-HTTP puffert Streams oder ignoriert Idle-Timeout | Künstlicher Server mit verzögerten Frames, gesplittetem UTF-8/JSON, Abbruch, ungültigem Frame und warmem/kaltem Modell; exakte Anfragezählung und Reihenfolge. |
| Audio oder Secrets verlassen die vorgesehene Grenze | Negativtests für DNS-Namen, IPv4/IPv6, Redirects und Proxy-Umgebung; Request-Mitschnitt synthetischer Fixtures; redigierte Fehler/Logs. |
| Streaming erzeugt doppelte oder falsch sortierte Texte | Mehrsegment-Fixture mit variabler Antwortreihenfolge; genau ein logischer Cleanup-Aufruf nach vollständigem Zusammenfügen. |
| Mint wird durch lokale Inferenz überlastet | Begrenzte CPU-/RAM-/Temperaturmessung bei realer Hintergrundlast; kein Dauer-Warm-up im Standard; Rohtext bleibt erreichbar. |
| Gemeinsamer VRAM für Whisper und lokales LLM reicht nicht | Lokalen Cleanup-Rückfall bei geladenem Whisper prüfen; kontrollierter CPU-Pfad statt OOM-Schleife. |
| Desktopfunktionen variieren | Laufzeitfähigkeiten statt Distributionsnamen; echte X11-/Wayland-Abnahme nach Desktopupdates. |
| Neue Linux-Struktur beschädigt Mac-Verhalten | Bestehende Swift-Tests plus macOS-App-Bundle-Smoke-Test und Audio-E2E; Signatur-/Releasepfade unverändert prüfen. |
| GUI-/Worker-Abbruch verliert Audiodiagnose | Kill-/Cancel-Tests während Aufnahme, Transkription und Cleanup; WAV nach Fehler vorhanden, nach vollständigem Erfolg entfernt. |
| Updater ist eigene sicherheitskritische Oberfläche | Enges Manifest, bewährte Signaturbibliothek, negative Pakettests und unabhängiges Review vor Freigabe; keine Installation allein aufgrund von HTTPS. |

Nicht zum ersten Linux-Release gehören die iOS-Empfängerbrücke, CoreML-Silero,
universelle Wayland-App-Erkennung, ARM-Pakete sowie ein eigenes APT-/Pacman-
Repository. Bestehende Kernfunktionen dürfen nur dann in der Linux-Oberfläche
erscheinen, wenn ihr Adapter tatsächlich funktioniert; spätere Ergänzungen
werden im zentralen Backlog priorisiert.
