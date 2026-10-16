# Ausgangsprüfung am 2026-10-16

Geprüft wurde die Quellbasis `6e7dce3` mit Produktversion 0.9.20. Ein dabei
reproduzierter Fehler in den Brücken-Einstellungen wurde in 0.9.21 korrigiert
und am notarisierten App-Bundle auf einem zweiten Apple-Silicon-Mac nachgeprüft.
Build- und Testsysteme verwendeten macOS 26.7.1.

## Bestandene Prüfungen

- `swift build`, `swift test` und der Release-Bundlebau.
- Die vorhandenen Shell-Verträge für Signaturpfade, CLI-Aufrufe, sichere
  Modellinstallation und Release-Schutz. Diese Tests führten keine öffentliche
  Veröffentlichung aus.
- `scripts/e2e-test.sh`: künstliche deutsche Aufnahme über Whisper und
  anschließende worttreue Bereinigung.
- Signatur, Notary-Ticket und Gatekeeper des geprüften Bundles. App und CLI der
  bereits installierten 0.9.20 stimmten mit dem frisch gebauten Release-Code
  überein; der Fix wurde anschließend als 0.9.21 gebaut und notarisiert.
- Wörterbuch in DE/EN bearbeiten, speichern, erneut öffnen und Änderungen
  abbrechen. Die gespeicherte Konfiguration wurde unabhängig von der Anzeige
  geprüft.
- Brücke in DE/EN einschalten, den Port ändern, den alten Listener schließen,
  abschalten und die Testkonfiguration zurücksetzen. Anfragen bestätigten die
  tatsächlich geöffneten und geschlossenen Ports. Die einmalige macOS-Nachfrage
  zum lokalen Netzwerk wurde für die App bestätigt; danach wurden die Ansichten
  ohne diesen Dialog erneut geprüft. Das ersetzt keine Firewall-Abnahme.
- Netzwerkprüfung gegen eine isolierte Instanz der echten App: fehlendes Token
  wird auf allen drei Routen mit HTTP 401 abgewiesen; gültige Health-Anfrage und
  AAC-Diktat über `.local` liefern HTTP 200. Ein vollständig übertragener Request
  wird auch nach TCP-Sendeschluss beantwortet.

## Korrigierter Fehler

Beim Einschalten der Brücke blieb das Einstellungsfenster auf dem Testsystem
stehen. Eine Prozessprobe zeigte den Hauptthread in
`BridgeRow.body → BridgeAddress.baseURL → ProcessInfo.hostName → NSHost` wartend
auf DNS-Auflösung. Die Adresse verwendet jetzt den direkt aus der lokalen
Systemkonfiguration gelesenen Bonjour-Namen. Der gleiche Bedienablauf bestand
danach in beiden Oberflächensprachen.

## Künstliche Referenzdiktate

Die Dateien wurden mit der deutschen Systemstimme erzeugt und als 16-kHz-Mono-WAV
verarbeitet. Erkennungssprache war fest Deutsch; die lokale Bereinigung verwendete
`gemma4:e4b-it-qat` mit `num_ctx=16384`. Dies ist ein kleiner Funktionsbeleg,
kein Modellvergleich oder Qualitätsbenchmark.

| Fall | Audiodauer | Dateiverarbeitung |
|---|---:|---:|
| Kurze Bestätigung | 1,565 s | 0,357 s |
| Technische Begriffe | 4,575 s | 0,461 s |
| Betrag und Termin | 9,297 s | 0,654 s |
| Verneinungen | 5,499 s | 0,498 s |
| Längerer zusammenhängender Text | 106,171 s | 5,289 s |

Die Dateiverarbeitung umfasst den CLI-Aufruf mit Erkennung und Bereinigung.
Sie misst weder eine Live-Aufnahme noch die Wartezeit vom Aufnahmestopp bis zum
Einfügen. Die kurzen Gegenproben erhielten die erwarteten Fachbegriffe, Zahlen
und Verneinungen; alle Dateien wurden erfolgreich verarbeitet.

## Noch offene Abnahmen

- Reale Wechsel des Standardmikrofons und Verlust eines USB-/Bluetooth-Geräts
  während einer Aufnahme. Das Testsystem stellte nur ein virtuelles Eingabegerät
  bereit; Kerngegenproben ersetzen diese Hardwarefälle nicht.
- Diktat vom echten iPhone über den eingerichteten Kurzbefehl. Die AAC-Netzprobe
  ersetzt keine iPhone-Bedienungsabnahme.
- Einmalige App-Freigabe bei aktiver macOS-Firewall. Die Firewall war auf dem
  Testsystem ausgeschaltet und wurde nicht für die Prüfung umkonfiguriert.
- Aufwecken aus dem Ruhezustand durch ein eingehendes Diktat.

Diese Fälle bleiben im [Backlog](../backlog.md) offen. Die übrigen historischen
Abnahmen, etwa Modell-Download und echter Anmeldezyklus, werden durch diese
Prüfung nicht pauschal geschlossen.
