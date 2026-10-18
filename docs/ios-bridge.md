# Diktat vom iPhone über das Heimnetz

Stand: 2026-10-18. Ab 0.9.42 verwendet die Brücke ausschließlich HTTPS. Die
native iPhone-App koppelt sich direkt am Mac per QR-Code. Eine Aufnahme endet
nach ausdrücklichem Stoppen; gesendet wird erst mit „An meinen Mac senden“.

## Einrichtung und Erstvertrauen

1. Mac: Einstellungen → Allgemein → „Diktat von eigenen Geräten (Heimnetz)“
   aktivieren. Port wählen, Einstellungen speichern, erneut öffnen und
   „iPhone koppeln …“ wählen. Fehlende Identität und Token werden erst dort
   beziehungsweise beim ausdrücklichen Listenerstart im Schlüsselbund angelegt.
2. iPhone: „Verbindung zum Mac“ → „QR-Code scannen“. Kamera- und lokale
   Netzwerkfreigabe sind erforderlich. Ausschließlich direkt den Code auf dem
   **eigenen Mac-Bildschirm** scannen. Ein Code aus einer Nachricht oder Webseite
   ist keine sichere Erstkopplung.
3. Adresse und vollständigen SHA-256-Fingerabdruck mit der Mac-Anzeige vergleichen,
   dann „Kopplung bestätigen“. Das speichert die Verbindung; noch kein Audio
   verlässt das iPhone. „Verbindung prüfen“ testet die verschlüsselte Brücke.
4. Aufnehmen, ausdrücklich stoppen, bewusst senden, Ergebnis manuell kopieren.
   Die App-Aktion „Diktat öffnen“ kann einem Kurzbefehl oder der Aktionstaste
   zugewiesen werden. Sie startet keine Aufnahme automatisch.

Der QR-Code enthält genau `v`, `url`, `pin` und `token`: Formatversion 1,
HTTPS-Adresse, SHA-256 des DER-Blattzertifikats und Bearer-Token. Er ist ein
Zugangsschlüssel: nicht fotografieren, weitergeben, loggen oder in Diagnosebelegen
speichern. Die Anzeige schließt nach zwei Minuten oder beim ausdrücklichen Ausblenden. Für
Bedienungshilfen können Adresse, Fingerabdruck und Token direkt vom eigenen Mac
übertragen werden; der Token wird nur über die vorhandene Kopieraktion ausgegeben.

## TLS-Identität und Pinning

Der Mac erzeugt einen ECDSA-P256-Schlüssel und ein selbstsigniertes
SHA-256-Serverzertifikat. Der private Schlüssel ist nicht exportierbar und bleibt
im Schlüsselbund; es gibt keine privaten Schlüsseldateien oder eine systemweit
installierte Vertrauens-CA. Die Identität bleibt über Listener- und App-Neustarts
stabil. Ein Schlüsselbundfehler ersetzt sie nicht stillschweigend.

Das Zertifikat gilt ein Jahr. „TLS-Zertifikat erneuern …“ erzeugt nach Bestätigung
ein neues Zertifikat mit demselben privaten Schlüssel und einem neuen Fingerabdruck.
Danach alle Geräte direkt am Mac neu koppeln. Ein neuer Mac oder eine verlorene
Identität verlangt ebenfalls neue Kopplung. Die Erneuerung ist kein Austausch eines
kompromittierten privaten Schlüssels; in diesem Fall Brücke abschalten, die
betroffene Identität im Schlüsselbund entfernen und anschließend Identität und
Token neu anlegen.

Beide Seiten verlangen mindestens TLS 1.2. Der iPhone-Client vergleicht zunächst
das tatsächlich präsentierte Blattzertifikat mit dem per QR übernommenen Pin.
Erst danach prüft Apples SSL-Serverpolicy Signatur, Serverzweck und Gültigkeit,
mit ausschließlich diesem Blatt als Trust-Anker und ohne Zertifikatsnachladen
über das Netz. DNS liefert die Adresse, aber keine Identität: Die Policy prüft
keinen DNS-Namen, weil der physisch übernommene Pin die Mac-Identität bindet.
Ein abweichender Pin oder ungültiges/abgelaufenes Zertifikat stoppt den Auftrag
**vor** Bearer-Token und Audio. Es gibt keinen Trust-all-Schalter, kein TOFU und
keine ungeprüfte Übernahme eines Fingerabdrucks aus dem Netz.

Adresse, Pin und Token bilden einen atomar gespeicherten, gerätegebundenen
Schlüsselbundeintrag auf dem iPhone, nur bei entsperrtem Gerät zugänglich und ohne
Synchronisation. Redirects, Mobilfunk, Proxys, Cookies und Antwort-Caches bleiben
gesperrt. Die App sendet nicht automatisch erneut.

## Tokenwechsel und Neu-Kopplung

„Neues Token“ verlangt eine Bestätigung, widerruft die bisherige Berechtigung und
startet den Listener neu. Laufende und wartende Brückenaufträge werden storniert;
noch nicht abgeholte Ergebnisse werden nicht zugestellt. Bereits erfolgte
Verarbeitung lässt sich dadurch nicht rückgängig machen. Auch `bridge token --new`
in der CLI benachrichtigt laufende Listener desselben Schlüsselbundservice ohne
Zugangsdaten in der Nachricht. Danach jedes iPhone erneut koppeln.

Bei „Identität stimmt nicht überein“ nicht einfach einen Netz-Fingerabdruck
übernehmen. Erst am Mac prüfen, ob Zertifikatserneuerung, Rechnerwechsel oder eine
andere bekannte Änderung vorliegt. Nur dann den neuen QR-Code direkt dort scannen.
Bei `401` ist das Token ungültig oder fehlt; nach Tokenwechsel neu koppeln.
Nichterreichbarkeit, Queue-Überlast und zu große Aufnahmen bleiben eigene Fehler.
Versandfehler und Abbruch erhalten die iPhone-Aufnahme zum erneuten Senden oder
Verwerfen.

## Migration bisheriger HTTP-Kurzbefehle

0.9.41 und ältere Mac-Brücken verwendeten HTTP. **0.9.42 beendet diese
Klartext-Unterstützung vollständig**, auch im Debug-Client. Es gibt weder einen
zusätzlichen HTTP-Port noch automatischen Klartext-Rückfall. Alte iPhone-Einträge
lassen sich laden, erlauben aber keinen Versand und verlangen neue QR-Kopplung.

Vorhandenen Heimnetz-Kurzbefehl so umstellen:

1. Den bisherigen Block „Audio aufnehmen → Inhalte von URL abrufen → Wörterbuchwert
   abrufen → Zwischenablage“ durch die App-Aktion **„Diktat öffnen“** ersetzen.
2. Die native App einmal per QR koppeln. Danach dort aufnehmen, stoppen, senden
   und kopieren. Der Kurzbefehl kann weiter an der Aktionstaste liegen.
3. Alte HTTP-URL und Bearer-Header aus dem Kurzbefehl entfernen. Nach Umstellung
   der Geräte auf dem Mac das Token rotieren und alle Geräte neu koppeln.

Kurzbefehle bieten hier kein appinternes Zertifikats-Pinning. Ein bloßer Wechsel
von `http` zu `https` reicht beim selbstsignierten Zertifikat nicht. Eine CA-
Installation oder Ausnahme für ungeprüfte Zertifikate gehört nicht zum
Migrationsweg. Der unabhängige Unterwegs-Kurzbefehl „Text diktieren → Zwischenablage“
mit Apples Erkennung bleibt möglich. Kein WAN-Zugang und keine eigene Tastatur-
Erweiterung; Offline-Erkennung der nativen App ist noch ein eigener Ausbauschritt.

## Mac-Brücke und Schutzgrenzen

Die Mac-App ist reiner Audioempfänger. Nur eigene Geräte im Heimnetz dürfen
Aufnahmen senden; der Mac verarbeitet sie über den lokalen Whisper-Server.
`WhisperEndpoint` erzwingt weiterhin Loopback. Nur fertiger Text darf entsprechend
der aufgelösten Datenschutz-/Profilkonfiguration zur Bereinigung gehen.

| Baustein | Aufgabe |
|---|---|
| `BridgeServer` | TLS-Listener, Verbindungen, Fristen und gemeinsames Speicherbudget |
| `BridgeIdentity` | Native Schlüsselbundidentität und ausdrückliche Zertifikatserneuerung |
| `BridgePairing` | Minimale QR-Verbindungsdaten |
| `BridgeProtocol` | HTTP-Ausschnitt, Größen- und Heimnetzprüfung |
| `BridgeRouter` | Tokenpflicht, begrenzte serielle Warteschlange und Routen |
| `BridgeToken` | Schlüsselbundtoken, Rotation und konstanter Vergleich |
| `AudioDecoder` | AAC/MP3/WAV → 16 kHz mono für Whisper |

- Standardmäßig aus. Ohne Token oder lesbare Identität kein offener Listener.
- Heimnetzprüfung vor der Verarbeitung: private IPv4, Link-Local, IPv6-ULA und
  globale IPv6-Adressen im selben Netzbereich wie der Mac. Öffentliche Gegenstellen
  werden unabhängig vom Token abgewiesen.
- Standardgrenze 25 MiB je Anfrage, Kopfzeilengrenze, 30 Sekunden Lesefrist,
  höchstens acht offene Verbindungen einschließlich TLS-Handshakes.
- Höchstens drei schwere Aufträge einschließlich laufender Arbeit; Überlast `503`.
  Ein gemeinsames Bytebudget begrenzt auch Teil-Bodys und bereits geparste Aufträge.
- Ein TLS-Verbindungsende vor der Antwort storniert wartende/laufende Arbeit.
  Der frühere TCP-Halbschluss ist kein TLS-Clientvertrag. Clients lesen die Antwort
  anhand von `Content-Length` und schließen danach TLS. Eine Anfrage je Verbindung,
  kein Keep-alive und keine Chunked-Anfragen.
- Pro Diktat genau eine Transkription und eine Bereinigung über den vollständigen
  Text. Stille benötigt keinen Cleanup. Profil-/Formatierungs-/Datenschutzsnapshot
  sowie Rohtext-Rückfall und WAV-Verträge bleiben erhalten.
- `bridge.log` enthält Methode, Pfad, Status, Größe und Dauer, keine Diktate,
  Tokens, privaten Schlüssel oder QR-Inhalte.

Alle Routen verlangen `Authorization: Bearer <token>`:

- `GET /v1/health`: `ok`, Produktversion und Cleanup-Verfügbarkeit.
- `POST /v1/dictate`: Audio als Body; Antwort mit fertigem Text, Rohtext und
  Phasenzeiten. `?raw=1` überspringt die Bereinigung.
- `POST /v1/cleanup`: UTF-8-Rohtext, gleiche Antwortform ohne Audio.

## Betrieb und Prüfung

Der Mac muss wach und aus dem Heimnetz erreichbar sein. Die macOS-Firewall kann
beim ersten Zugriff eine Freigabe verlangen. Sleep/Wake und Firewallverhalten
hängen vom tatsächlich geprüften Rechner ab; TLS ersetzt diese Abnahme nicht.

Die CLI behält `bridge status`, `bridge token [--new]` und `bridge serve`.
`bridge status` nennt jetzt eine HTTPS-Adresse. Eigene Diagnoseclients müssen den
Pin beziehungsweise das direkt vom Mac bezogene Zertifikat prüfen. `curl -k` oder
`--insecure` sind kein zulässiger Prüfersatz. Für Token keine Terminalargumente
verwenden; eine private Headerdatei kann vorübergehend mit Modus 0600 angelegt und
nach dem Test entfernt werden.

Automatisierte TLS-/Brückenprüfungen:

```bash
swift test --filter 'BridgeIdentityTests|BridgeTests'
swift test --package-path iOS/StillePostClientCore
```

Die native App, Build-/Geräteprüfung und tatsächlichen Plattformgrenzen stehen in
[iOS/README.md](../iOS/README.md). Die historische HTTP-Sprechprobe von 2026-07-29
belegt den damaligen AAC-Pfad, aber keine TLS-Abnahme. Am 2026-10-18 wurden mit
0.9.42 echte QR-/HTTPS-Kopplung, AAC-Diktat, Kopieren und die Pin-/Token-/
Zertifikatswechsel auf iOS 26.6.2 gegen macOS 26.7.1 geprüft. Auch der HTTPS-
Versandabbruch während der Bereinigung, Aufnahmeerhalt nach App-Neustart und
ausdrückliches erneutes Senden sind bestanden. Die laufende Bereinigungsanfrage
wurde beendet, ohne automatisch erneut anzufragen; nach dem erfolgreichen
Wiederholen waren Audio und Metadaten auf dem iPhone entfernt. Die native
Mac-Anzeige wurde in DE/EN auf Öffnen, Fokuswechsel und Schließen geprüft,
ihre Zweiminutenfrist unter DE
bestätigt. Der Ausblendfall blieb unbelegt, weil sich die Menüleisten-App auf dem
geprüften macOS weder per API noch per ⌘H ausblenden ließ.

Technische Grundlage: Apples Dokumentation zu
[manueller Serverprüfung](https://developer.apple.com/documentation/foundation/performing-manual-server-trust-authentication)
und [Trust-Ankern](https://developer.apple.com/documentation/security/configuring-a-trust).
