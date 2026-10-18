# Stille Post auf dem iPhone

Native SwiftUI-App ab iOS 17. Der aktuelle Stand ist ein **Entwicklungsclient**
für die vorhandene Mac-Brücke. Verschlüsselte Kopplung steht noch aus; HTTP ist
ausschließlich im Debug-Build und nach ausdrücklicher Freigabe in der App möglich.
Der Release-Build verweigert diesen Transport.

## Benutzung im Entwicklungstest

1. Auf dem Mac die Heimnetzbrücke ausdrücklich aktivieren und deren Adresse und
   Token über die vorhandenen Einstellungen übernehmen.
2. Auf dem iPhone „Verbindung zum Mac“ öffnen, die vollständige Adresse
   `http://<mac-name>.local:8188` und das Token einfügen. Den unverschlüsselten
   Entwicklungstest bewusst erlauben, speichern und die Verbindung prüfen.
3. „Aufnehmen“ antippen und den Mikrofonzugriff erlauben. Das Satzende stoppt die
   Aufnahme nicht automatisch. Nach dem Sprechen „Aufnahme stoppen“ antippen.
   Das Audio liegt weiterhin nur auf dem iPhone. Erst „An meinen Mac senden“
   startet die Übertragung; dabei benötigt iOS die lokale Netzwerkfreigabe.
4. Den fertigen Text ausdrücklich kopieren und in der gewünschten App einsetzen.
   Die Zwischenablage bleibt lokal auf diesem Gerät und läuft nach zwei Minuten ab.

In Kurzbefehle ist „Diktat öffnen“ als App-Aktion vorbereitet. Ein entsprechender
Kurzbefehl kann der Aktionstaste zugewiesen werden. Er öffnet die App; das Mikrofon
startet erst nach dem Antippen. Es gibt keine Tastatur-Erweiterung und keinen
Hintergrund-Recorder.

## Grenzen und Dateiverhalten

- Eine ausstehende Aufnahme, höchstens 180 Sekunden und 5.000.000 Byte. AAC mono
  mit 16 kHz und 32 kbit/s; eine niedrigere Grenze des Macs kann zusätzlich greifen.
- Ein erfolgreicher Brückenaufruf entfernt die eigene Aufnahme. Bei Fehler oder
  abgebrochenem Versand bleibt sie zum ausdrücklichen erneuten Senden oder
  Verwerfen erhalten, auch nach einem App-Neustart. Neue Aufnahmen überschreiben
  sie nicht. Ein expliziter Aufnahmeabbruch verwirft sie.
- Beim Wechsel in den Hintergrund oder Verlust des Audioeingangs wird die
  Aufnahme beendet beziehungsweise der Versand abgebrochen. Es gibt keine
  automatische Fortsetzung oder Wiederholung. Ein Abbruch kann bereits auf dem
  Mac begonnene Verarbeitung nicht rückgängig machen.
- Audio liegt unter dem iOS-Dateischutz und wird von Backups ausgeschlossen.
  Das Token liegt im gerätegebundenen Schlüsselbund, nur bei entsperrtem Gerät
  zugänglich und ohne Synchronisation. Es steht nicht in den Einstellungen-Dateien.
- Zulässig sind `.local`-Namen sowie private IPv4-, ULA-, Link-Local- und
  Loopback-Literaladressen. Öffentliche Ziele, URL-Zugangsdaten und Weiterleitungen
  werden abgewiesen. Mobilfunk, Proxys, Cookies und Antwort-Caches sind abgeschaltet.
  Die Antwortgrenze von 1 MiB gilt bereits während des Empfangs.
- Die Mac-Brücke bleibt unverändert: lokales Whisper, genau eine Bereinigung des
  vollständigen Textes und ihre bestehenden Token-, Netz- und Warteschlangengrenzen.
  macOS 13 und die bisherigen Mac-Detektoren bleiben erhalten.

HTTP schützt Audio und Token nicht gegen Mitlesen im Heimnetz. Dieser Stand ist
für bewusste Entwicklungsprüfungen bestimmt und wird nicht als fertiger sicherer
Client veröffentlicht. Einzelheiten zur Mac-Seite: [Heimnetzbrücke](../docs/ios-bridge.md).

## Bauen

Das versionierte Xcode-Projekt benötigt keine Projektgenerierung zum Bauen.
Benötigt wird ein Swift-6-fähiges Xcode mit iOS-SDK. Geprüft wird der tatsächlich
vorhandene SDK-/Gerätestand; daraus folgt kein Test aller unterstützten iOS-Versionen.

```bash
./iOS/build.sh                 # Simulator, Debug, lokale Signatur
./iOS/build.sh --release       # Simulator, HTTP gesperrt
DEVELOPMENT_TEAM='<team-id>' ./iOS/build.sh --device
```

Die Ergebnisse liegen unter `build/iOS-<Konfiguration>-<simulator|device>/`.
Geräteinstallation und Geräteprüfung benötigen ein passendes Entwicklungsprofil,
ein gekoppeltes iPhone und Developer Mode. Signing-Team und Gerätekennung sind
lokale Buildparameter; sie gehören nicht ins Projekt. Die Mac-Einstiegsskripte
im Repo-Root behalten ihre bisherige Aufgabe.

`project.yml` beschreibt das Projekt zusätzlich reproduzierbar. Nur bei einer
Änderung an der Projektstruktur mit installiertem XcodeGen neu erzeugen:

```bash
xcodegen generate --spec iOS/project.yml
```

Das Icon nutzt das bestehende Projektmotiv mit voller iOS-Hintergrundfläche.
Die PNG-Datei ist eingecheckt; nur zum Neuzeichnen ist `rsvg-convert` nötig:

```bash
rsvg-convert --width=1024 --height=1024 --background-color='#4338ca' \
  --output=iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png iOS/Resources/AppIcon.svg
```

## Prüfung

Auf einem iPhone 16 Pro Max mit iOS 26.6.2 wurden Mikrofon- und lokale
Netzwerkfreigabe, echtes AAC-Diktat über `.local`, Ergebnis und Kopieren geprüft.
Die manuelle Sprechprobe gelang nach Korrektur der AAC-Bitrate auf 32 kbit/s.
Nach einer App-Unterbrechung bleibt die Aufnahme erhalten. Eine künstliche Datei
mit 5.000.001 Byte wird vor dem Versand abgewiesen. Bei Versandabbruch oder
Verbindungsabbruch bleibt die Datei erhalten. Nichterreichbarkeit wird
verständlich angezeigt.
DE/EN und große Schrift wurden zusätzlich im Simulator visuell geprüft,
einschließlich Querformat. Xcode 27.1 baute Geräte-, Simulator- und Release-Ziele.
iOS 17 als Mindestversion wurde nicht auf einem eigenen Gerät geprüft.

```bash
swift test --package-path iOS/StillePostClientCore
swift test --package-path iOS/StillePostClientCore -c release \
  --filter testReleaseBlocksHTTPDespiteDevelopmentConsent
xcodebuild -project iOS/StillePostMobile.xcodeproj -scheme StillePostMobile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGN_IDENTITY=- build-for-testing
```

UI-Tests laufen auf einer ausdrücklich gewählten Simulator-/Geräte-ID. Die
gewöhnlichen Layouttests benötigen keinen Server. Die zusätzlichen Geräte-/
Brückentests sind standardmäßig übersprungen und verlangen vorbereitete private
Testdaten und ihre jeweilige Buildvariable:
`STILLEPOST_RUN_BRIDGE_UI_TEST=1` für den Simulator oder
`STILLEPOST_RUN_DEVICE_BRIDGE_TEST=1` für die begleitete echte iPhone-Probe.

Der Debug-Testimport liest bei
`STILLEPOST_MOBILE_IMPORT_TEST_CONNECTION=1` eine höchstens 4 KiB große
`Documents/development-connection.json` mit `address` und `token`, speichert das
Token im Schlüsselbund und entfernt die Datei. Echte Tokens niemals in
Kommandozeilen oder UI-Test-Texte einsetzen. Für automatisierte Tests einen
eigenen kurzlebigen Testserver mit eigenem Token verwenden.

`STILLEPOST_MOBILE_SYNTHETIC_CAPTURE=1` existiert ausschließlich in
Simulator-Debug-Builds. Es benutzt künstliches AAC aus
`Documents/development-audio.m4a` für native Bedienungs-/Versandprüfungen.
Dieser Ersatz ist auf echten Geräten nicht kompiliert. Er belegt keine
Mikrofonaufnahme. `scripts/fixtures/ios-bridge-server.swift` erlaubt separat eine
isolierte Geräteprobe gegen die echte Mac-Brücke und die vorhandenen lokalen
Modelle; seine Messdatei enthält Zähler und Prüfbefunde, keine Diktate oder Tokens.
