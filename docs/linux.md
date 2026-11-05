# Stille Post unter Linux

Der Linux-Port verwendet denselben Swift-Diktierkern wie macOS und eine
Qt-Oberfläche. Zielplattformen sind x86_64 mit CachyOS/KDE unter Wayland und Linux
Mint 22.2/Cinnamon unter X11. Sie benötigt mindestens glibc 2.39, Python 3.10,
eine PulseAudio-kompatible Audiositzung (zum Beispiel PipeWire) und für den
GPU-Pfad einen funktionierenden Vulkan-Treiber. CPU bleibt konfigurierbar.

**Stand 0.9.48:** Der erweiterte Funktionsumfang ist auf den beiden Zielsystemen
installiert und mit künstlichen Audioquellen geprüft. Physische Geräteabnahme,
mehrtägiger Betrieb und öffentliche Updatefreigabe stehen noch aus.
Verbindliche Funktionen, bestandene Prüfungen und offene Grenzen stehen im
[Mac-/Linux-Abgleich](linux-paritaet.md). Die [erste Paketprüfung](linux-abnahme.md)
dokumentiert ausdrücklich den älteren, eingeschränkten Stand von 0.9.47.

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

Die App läuft im Tray und öffnet eigene Fenster für Einstellungen, Verlauf,
Diagnose, Testdiktat, Audioimport und Ergebnisse. Die Einstellungen folgen den sieben
Mac-Bereichen Allgemein, Profile, Apps, Bereinigung, Spracherkennung, Aufnahme
und Verlauf. Deutsch, Englisch und helle/dunkle Darstellung sind verfügbar.
Das Schließen eines Fensters beendet die App nicht; dazu dient das Tray-Menü.

Die globalen Vorgaben sind **Strg+Alt+Leertaste** für Diktate und
**Strg+Alt+R** für den letzten bestätigten Text. Start/Stopp und Gedrückthalten
sind wählbar. Unter Wayland verwaltet das GlobalShortcuts-Portal die Freigaben
und tatsächlichen Kombinationen; die Einstellungen zeigen dessen Zuweisung
und öffnen die Desktop-Konfiguration. Unter X11 werden freie Kombinationen
direkt registriert. Maßgeblich ist die tatsächlich von der Tastatur gelieferte
Kombination. Konflikte und ausstehende Freigaben werden angezeigt; die
Aufnahmeschaltfläche bleibt benutzbar.

Automatisches Einfügen prüft über AT-SPI das ursprüngliche Feld, Text, Auswahl,
Fokus und Schreibbarkeit erneut. Ein zwischenzeitlich geändertes oder
ungeeignetes Ziel wird nicht blind beschrieben. Dann wird der Text zum
manuellen Einfügen kopiert oder bei fehlender Clipboard-Berechtigung sichtbar
in einer Vorschau erhalten. Geschützte Felder werden nicht ausgelesen. Bei
erfolgreichem direktem Einfügen bleibt die Zwischenablage unverändert.

Die optionale schreibgeschützte Ergebnisvorschau bietet Verwerfen, Kopieren und
Einfügen. Mehrere offene Ergebnisse bleiben in Zustellreihenfolge erhalten;
„Letzter Text“ übernimmt nur ausdrücklich bestätigte Vorschauen. Der Verlauf
bietet Suche, Status-/Zeitraumfilter, Rohtext und Ergebnis, Änderungsvergleich,
Korrekturen, erneute Bereinigung, Wiederholung fehlgeschlagener Aufnahmen und
bewusste Wörterbuchübernahme. Profile vererben ihre Bereiche unabhängig und
lassen sich Linux-Apps zuordnen oder manuell wählen.

Testdiktat und Audioimport zeigen das angewendete Profil und seine
Aufbewahrungsregeln vor dem Start. Ändern sich diese Einstellungen, muss die
Freigabe ausdrücklich aktualisiert werden. Audiodateien lassen sich auswählen
oder einzeln ins Importfenster ziehen; die Transkription beginnt erst nach
Bestätigung. Ergebnisse bleiben schreibgeschützt und werden nicht automatisch
eingefügt. Der Phasenbericht des Testdiktats lässt sich ohne Testtext oder private
Konfigurationsdaten kopieren.

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

Silero ist optional und lädt das gepinnte offizielle ONNX-Modell erst auf
Anforderung in den Aufnahmeeinstellungen. Die CPU-Laufzeit ist mitgeliefert.
Fehlende, beschädigte oder nicht ausführbare Modelle fallen ausdrücklich auf
RMS zurück. Linux und die Mac-CoreML-Referenz verwenden dieselbe Schwelle und
Aggregation; der datierte Vergleich steht im Abnahmebericht.

Die optionale iPhone-Brücke empfängt über HTTPS; sie sendet selbst kein Audio.
Sie bleibt standardmäßig aus und verlangt Token, Zertifikat-Pin und eigenes
Netz. Kopplung und Erneuerung sind in Allgemein verfügbar. Für `.local`-Adressen
muss die lokale mDNS-Auflösung funktionieren, beispielsweise über Avahi.
Zertifikat und privater Softwareschlüssel liegen im Secret Service; der
TLS-Prozess lädt den Schlüssel zur Verwendung in seinen RAM. Linux verwendet
hier keinen nicht exportierbaren macOS-Schlüsselbundschlüssel. Die echte
Gerätekopplung bleibt Bestandteil der noch offenen Abnahme.

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
macOS-Sparkle-Feed bleibt unter seiner eigenen Adresse erhalten. Die gemeinsame
Pages-Veröffentlichung wählt für jede Plattform das neueste stabile Release;
Linux-Manifest und Signatur werden vor der Übernahme erneut geprüft.

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
python3 linux/test_update_site.py
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
beiden GPU-Pfaden, LAN-Bereinigung und reale lokale Gemma-Fallbacks. Der Qt-
Aufnahmepfad unter Wayland und X11 wurde mit virtuellen Mikrofonen und künstlicher
Sprache geprüft. Ein physischer Mikrofontest, Hotkey-Abnahme am tatsächlich
gewählten Desktopkürzel, Gerätewechsel/Suspend und mehrtägiger Pilotbetrieb
bleiben eigene Abnahmeschritte. Ein reiner Monitor-Eingang ersetzt auf einem
Rechner ohne angeschlossenes Mikrofon keine echte Mikrofonabnahme.

Datierte Belege und offene Grenzen: [Mac-/Linux-Abgleich](linux-paritaet.md).
