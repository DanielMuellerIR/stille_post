# Stille Post unter Linux

Die erste Linux-Fassung verwendet denselben Swift-Diktierkern wie macOS und eine
Qt-Oberfläche. Geprüfte Ziele sind x86_64 mit CachyOS/KDE unter Wayland und Linux
Mint 22.2/Cinnamon unter X11. Sie benötigt mindestens glibc 2.39, Python 3.10,
eine PulseAudio-kompatible Audiositzung (zum Beispiel PipeWire) und für den
GPU-Pfad einen funktionierenden Vulkan-Treiber. CPU bleibt konfigurierbar.

## Installieren und starten

Aus dem Quellstand mit Docker:

```bash
./build.sh
./install.sh
```

`build.sh` erzeugt ausschließlich ein Archiv unter `build/`. `install.sh`
installiert benutzerlokal, ohne sudo und ohne Änderungen an Systemdiensten.
Alternativ das gebaute `StillePost-<version>-linux-x86_64.tar.gz` entpacken und
`StillePost.AppDir/install.sh` ausführen. Der Installer richtet das App-Menü und
`$HOME/.local/bin/stillepost` ein und prüft beziehungsweise lädt die Modelle.
Whisper benötigt ungefähr 1,6 GB, der Gemma-Fallback ungefähr 6,2 GB Plattenplatz;
die App-Laufzeit liegt zusätzlich im Benutzerkonto.

Start über das App-Menü **Stille Post** oder:

```bash
$HOME/.local/bin/stillepost
```

Die App bietet gespeicherte Mikrofonwahl, Start/Stopp, Abbruch, Pegelanzeige, Audiodateiimport,
Textausgabe, Kopieren, Verlauf mit Einzellöschung und Bereinigungseinstellungen.
Das Schließen des Fensters lässt die App im Tray weiterlaufen; Beenden erfolgt
über dessen Menü. Der erste Linux-Oberflächenstand ist deutsch; der gemeinsame
Kern behält seine deutschen und englischen Ressourcen.

Als globale Vorgabe dient **Strg+Alt+Leertaste**. KDE verwendet das
GlobalShortcuts-Portal und kann beim ersten Start eine Freigabe verlangen. Unter
X11 wird die Kombination direkt registriert, falls sie noch frei ist. Ist das
Portal nicht verfügbar oder das Kürzel belegt, bleibt die Aufnahmeschaltfläche
benutzbar. Alternativ im Desktop ein eigenes Kürzel für
`$HOME/.local/bin/stillepost --toggle` einrichten. Gedrückthalten ist in der ersten
Linux-Fassung noch nicht freigegeben.

**Der fertige Text wird kopiert und manuell eingefügt.** Die Linux-Fassung sendet
keine ungesicherten Tastaturereignisse an ein unbekanntes Eingabeziel und stellt
den vorherigen Clipboard-Inhalt nicht automatisch wieder her. Automatisches
Einfügen und anwendungsbezogene Profile sind noch keine abgenommenen
Linux-Funktionen. Die macOS-Fassung behält ihr bisheriges Einfügeverhalten.

## Mac-Bereinigung mit lokalem Fallback

In den Einstellungen den gewünschten Ollama-Dienst im eigenen Netz als primären
Endpunkt eintragen. Die Adresse wird lokal gespeichert, nie ins Repository.
Danach folgt Ollama auf `http://127.0.0.1:11434`. Beide verwenden
`gemma4:e4b-it-qat`, `think: false` und `num_ctx: 16384`. Vorhandene Wörterbücher
und geeignete Datenschutz-/VAD-Einstellungen können vom Mac übernommen werden;
Mac-Mikrofonkennungen, Schlüsselbundinhalte und Homebrew-Pfade dagegen nicht.
Ein zusätzlicher Cloud-Fallback wird durch die Linux-Oberfläche nicht angelegt.

Die App startet bei Bedarf einen eigenen, zunächst ungeladenen lokalen
Ollama-Dienst. Ein bereits laufender Dienst bleibt unangetastet. Lokale
Bereinigungsanfragen verwenden vier CPU-Threads und laufen nacheinander;
regelmäßiges Aufwärmen ist ohne ausdrücklich gewählte Dauerhaltung aus.
Ein auf zehn Minuten begrenztes Fallback-Keep-alive kann aus einer bestehenden
Mac-Konfiguration übernommen werden. Standardmäßig gelten die gemeinsamen
zwei Stunden für den Primärdienst und dreißig Minuten für Fallbacks.

Audio bleibt ausschließlich auf dem aufnehmenden Rechner. Whisper wird nur an
eine ausdrückliche Loopback-Adresse gebunden; Namen, Weiterleitungen und
geerbte Netzwerkproxies können den Audiotransport nicht ausleiten. Nur fertig
zusammengefügter Text erreicht den konfigurierten Bereinigungsdienst.
Netzwerkfehler wechseln den Dienst; verworfene Modellinhalte führen unmittelbar
zum deterministisch lesbar gemachten Rohtext. Die Oberfläche meldet diesen Fall.

## Dateien und Betrieb

- Konfiguration: `$XDG_CONFIG_HOME/stillepost/config.json`, gewöhnlich
  `$HOME/.config/stillepost/config.json`.
- Verlauf, Fehleraufnahmen, Whisper und lokale Ollama-Modelle:
  `$XDG_DATA_HOME/stillepost`, gewöhnlich `$HOME/.local/share/stillepost`.
- Installationen: dort unter `app/<version>`, aktiver Verweis `app/current`.
- Keine Audiodateien nach erfolgreichem Diktat; Fehleraufnahmen bleiben zur
  Diagnose erhalten. Textaufbewahrung folgt der gespeicherten Verlaufspolitik.
- API-Schlüssel nur über die konfigurierte Umgebungsvariable oder Secret Service.
  Die App liefert `secret-tool` mit, benötigt aber einen entsperrten Dienst des
  Desktops. Es gibt keinen Klartext-Schlüssel-Fallback.

`whisper.useGPU` steuert den Linux-Serverstart; `false` ergänzt `--no-gpu`.
`whisper.threads` begrenzt die CPU-Threads. Der mitgelieferte Server enthält CPU-
und Vulkan-Backend. Ein Modellwechsel erfolgt nicht automatisch.

Die Netzwerkbrücke für iPhone-Audio und CoreML-Silero sind in dieser Linux-Fassung
nicht enthalten. RMS-VAD bleibt verfügbar; eine übernommene Silero-Auswahl meldet
die fehlende Linux-Unterstützung und verwendet RMS.

## Updates

Die App sucht nach signierten Linux-Updates auf GitHub Pages, mit Paketen aus den
GitHub Releases dieses Projekts. Sie installiert erst nach Bestätigung und nur
im Leerlauf. Ed25519-Signatur, Produkt, Kanal, Architektur, Mindestplattform,
Version, Paketgröße und SHA-256 müssen passen. Archive werden gegen Pfadwechsel,
Links und übergroße Inhalte geprüft. Die neue Laufzeit wird vor dem atomaren
Versionswechsel isoliert gestartet. Der Launcher kann bei fehlgeschlagenem Start
einmal auf das bereits geprüfte Vorgängerpaket zurückgehen.

**Noch kein öffentliches Linux-Release veröffentlicht:** Der Updateclient und
sein Vertrauensanker sind enthalten; solange kein signierter Linux-Feed
veröffentlicht ist, meldet die manuelle Prüfung dessen fehlende Erreichbarkeit.
Ein normales Prüfen im Hintergrund bleibt bei diesem Zustand still. Das
Erzeugen des lokalen Installationspakets veröffentlicht nichts. Der vorhandene
macOS-Sparkle-Feed bleibt separat.

Ein Release-Manifest beschreibt `product`, `channel`, `arch`, monotone `build`,
`version`, `min_glibc`, `size`, `sha256` und die GitHub-Release-`url`. Die Signatur
liegt neben dem unveränderten JSON als `.sig`. `linux/sign-manifest.py` erhält den
privaten PEM-Schlüssel ausschließlich auf stdin; er gehört in den Release-
Secret-Store. Tests verwenden eigene kurzlebige Schlüssel. Der Updater akzeptiert
keine unbestätigten Schlüsselwechsel.

## Prüfungen und Grenzen

```bash
python3 linux/test_pipeline.py
python3 linux/test_update.py
QT_QPA_PLATFORM=offscreen build/linux/StillePost.AppDir/AppRun --smoke-test
```

Die gebündelte CLI wird mit `stillepost --cli --version` oder
`stillepost --cli --cleanup` aufgerufen. Bereinigung liest Text von stdin und
liefert JSON; Diktate gehören nicht als Prozessargument in die Kommandozeile.

Der Containerbuild führt außerdem die portablen Swift-Verträge aus. Pipeline-
Tests verwenden künstliche Samples und lokale Testdienste für Segmentreihenfolge,
einmalige Bereinigung, Ausfall, Worttreue, Redirect-/Proxy-Grenzen und WAV-Dateien.
`linux/smoke-real.py` prüft ein ausdrücklich übergebenes synthetisches
Referenzaudio gegen echte lokale Dienste, ohne dessen Text zu protokollieren.

Die erste Geräteprüfung umfasst korrekte deutsche Referenztranskription auf
beiden GPU-Pfaden, M5-Bereinigung und reale lokale Gemma-Fallbacks. Der Qt-
Aufnahmepfad unter Wayland und X11 wurde mit virtuellen Mikrofonen und künstlicher
Sprache geprüft. Ein physischer Mikrofontest, Hotkey-Abnahme am tatsächlich
gewählten Desktopkürzel, Gerätewechsel/Suspend und mehrtägiger Pilotbetrieb
bleiben eigene Abnahmeschritte. Ein reiner Monitor-Eingang ersetzt auf einem
Rechner ohne angeschlossenes Mikrofon keine echte Mikrofonabnahme.

Datierte Belege und offene Grenzen: [erste Linux-Abnahme](linux-abnahme.md).
