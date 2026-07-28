# Diktat vom iPhone über das Heimnetz

Stand: 2026-07-29 (Stufe 0 gebaut und verifiziert).

Ziel: auf dem iPhone in beliebigen Apps mit der Diktatqualität von Stille Post
arbeiten, solange man im eigenen Heimnetz ist. Der Mac erledigt Spracherkennung
und Textbereinigung, das iPhone nimmt auf und fügt den fertigen Text ein.

## Getroffene Entscheidungen

Diese Punkte sind bewusst entschieden und nicht erneut zu diskutieren, solange
sich die Lage bei Apple nicht ändert:

- **Keine eigene Tastatur-Erweiterung** (Daniel, 2026-07-29). Nur eine
  Tastatur-Erweiterung darf in ein fremdes Textfeld schreiben, aber sie darf nicht
  aufnehmen: Der Mikrofonzugriff endet dort mit dem `AVAudioSession`-Fehler
  `561145187` (`'!rec'`, „cannot start recording"), und ihr Speicherlimit von
  etwa 48–60 MB schließt jedes eigene Modell aus. Der Umweg, den kommerzielle
  Diktier-Tastaturen gehen — Tastatur öffnet die eigene App, App nimmt im
  Hintergrund auf, Text kommt über eine App-Gruppe zurück —, hat mit iOS 26.4
  zusätzlich die automatische Rückkehr zur vorherigen App verloren; der Nutzer muss
  seitdem selbst zurückwischen. Der Weg über **Action-Button und Zwischenablage**
  kostet einen Handgriff mehr, ist dafür stabil und von Apple nicht bedroht.
- **Kein Fernzugriff von unterwegs.** Die FRITZ!Box kann WireGuard nur über IPv6,
  und der Glasfaseranschluss hat keine von außen erreichbare IPv4-Adresse. Aus
  einem IPv4-only-Fremdnetz kommt man also gar nicht nach Hause. Unterwegs gilt
  deshalb: Apples eigenes Diktat oder — später — Whisper lokal auf dem iPhone,
  jeweils ohne Bereinigung. Das ist kein Verzicht, sondern die einzige Variante,
  die ohne Bastelei zuverlässig funktioniert.
- **Der iOS-Teil bleibt in diesem Repo.** Kein eigenes Repository. Solange die
  iPhone-Seite aus Kurzbefehlen besteht, ist ohnehin kein Xcode-Projekt nötig.

## Wie die Mac-Seite aufgebaut ist

Die Brücke ist **nur Empfänger**. Sie nimmt Audio oder Rohtext an und gibt
fertigen Text zurück; die Verarbeitung passiert vollständig auf dem Mac. Damit
bleibt die strengste Regel des Projekts wörtlich gültig: Stille Post überträgt
selbst niemals Audio irgendwohin, und die Loopback-Prüfung in `WhisperEndpoint`
wurde nicht angetastet.

Bausteine (alle in `StillePostCore`, damit App und CLI dieselbe Logik nutzen):

| Datei | Aufgabe |
|---|---|
| `BridgeServer.swift` | TCP-Listener (Network.framework), Verbindungsverwaltung, Protokollzeilen |
| `BridgeProtocol.swift` | der kleine HTTP-Ausschnitt, Größengrenzen, Adressprüfung |
| `BridgeRouter.swift` | Token-Prüfung und die drei Routen; `actor`, arbeitet Anfragen einzeln ab |
| `BridgeToken.swift` | Zugangs-Token im Schlüsselbund, Vergleich in konstanter Zeit |
| `AudioDecoder.swift` | AAC/MP3/WAV → 16 kHz mono für Whisper |

Umgesetzt ist absichtlich nur ein Bruchteil von HTTP: eine Anfrage pro
Verbindung, `Content-Length` statt Chunked-Kodierung, kein Keep-alive. Mehr
braucht weder ein Kurzbefehl noch `curl`, und weniger Code heißt weniger
Angriffsfläche.

### Routen

Alle Routen verlangen `Authorization: Bearer <token>`.

- `GET /v1/health` → `{"ok":true,"version":"0.9.2","cleanup":true}`
- `POST /v1/dictate` → Audio im Anfragetext (WAV, AAC/m4a, MP3, …), Antwort:
  `{"text":"…","raw":"…","sttSec":1.2,"cleanupSec":1.5,"usedFallback":false,"endpoint":"…"}`.
  `?raw=1` überspringt die Bereinigung.
- `POST /v1/cleanup` → Rohtext als UTF-8 im Anfragetext, gleiche Antwortform.
  Damit kann ein Gerät, das selbst transkribiert, die Textqualität nutzen, **ohne
  Audio zu übertragen**.

Die Architekturregel „genau eine Bereinigung über den vollständigen Text" gilt
auch hier: `POST /v1/dictate` transkribiert einmal und bereinigt einmal. Auf reine
Stille wird gar kein Modell bemüht.

### Schutzmaßnahmen

- Standardmäßig **aus** (`bridge.enabled = false`). Ein offener Port ist eine
  Entscheidung, keine Voreinstellung.
- Ohne Token im Schlüsselbund startet die Brücke nicht. Das Token wird nie
  angezeigt, nie in `config.json` geschrieben und nie als Kommandozeilenargument
  übergeben — es geht über die Zwischenablage aufs iPhone.
- Verbindungen aus dem öffentlichen Internet werden **vor** der Token-Prüfung
  abgewiesen: Nur private IPv4-Bereiche, Link-Local und IPv6-ULA gelten als
  Heimnetz. Ein global geroutetes IPv6-Präfix der FRITZ!Box zählt bewusst nicht,
  damit eine versehentliche Portweiterleitung die Brücke nicht ins Netz stellt.
- Größengrenze je Anfrage (Standard 25 MB), Kopfzeilen-Grenze, Lesefrist von 30 s,
  höchstens acht gleichzeitige Verbindungen.
- Protokollzeilen enthalten Methode, Pfad, Status, Größe, Dauer und Gegenstelle —
  **nie** Diktattext und nie das Token.

### Bekannte Grenze: die Verbindung ist unverschlüsselt

Text und Aufnahme gehen im Klartext über das WLAN. Für ein selbstsigniertes
Zertifikat gibt es in der Kurzbefehle-App keinen Weg, einen Fingerabdruck zu
hinterlegen — sie würde die Verbindung einfach ablehnen. Die Entscheidung lautet
deshalb: Stufe 0 läuft über HTTP im Heimnetz, und die Oberfläche sagt das
ausdrücklich. Wer im gleichen WLAN mitliest (etwa ein übernommenes
IoT-Gerät), kann Diktate mitlesen.

Verschlüsselung wird erst mit einer eigenen iPhone-App sinnvoll: Nur eigener Code
kann den Fingerabdruck des Zertifikats bei der Kopplung merken und danach
erzwingen. Das ist Stufe 1 im Backlog.

## Einrichtung

Auf dem Mac:

```bash
stillepost-cli bridge status      # Zustand, Adresse, Grenzen
stillepost-cli bridge token       # Token anlegen und in die Zwischenablage legen
stillepost-cli bridge serve       # zum Ausprobieren im Vordergrund
```

Im Alltag übernimmt die App: Einstellungen → Allgemein → „Diktat von eigenen
Geräten (Heimnetz)" einschalten, dort auch das Token in die Zwischenablage legen.
Von der Mac-Zwischenablage kommt es per Handoff direkt aufs iPhone.

Als Adresse den `.local`-Namen des Macs verwenden, nicht die IP-Adresse — der Name
bleibt gleich, wenn der Router eine neue Adresse vergibt:
`http://<mac-name>.local:8188`.

Voraussetzungen, die leicht übersehen werden:

- Der Mac muss **wach** sein. Ein Dauerläufer ist die richtige Grundlage; ein
  zugeklappter Laptop antwortet nicht.
- Die macOS-Firewall fragt beim ersten eingehenden Zugriff nach einer Freigabe.
- iOS fragt beim ersten Zugriff nach der Berechtigung für das lokale Netzwerk.

## Der Kurzbefehl auf dem iPhone

Zwei getrennte Kurzbefehle sind einfacher als einer mit Sonderfällen. Der erste
gehört auf den Action-Button.

**„Diktat" (zu Hause, volle Qualität)**

1. *Audio aufnehmen* — Start: sofort, Stoppen: beim Antippen.
2. *Inhalt von URL abrufen*
   - URL: `http://<mac-name>.local:8188/v1/dictate`
   - Methode: `POST`
   - Header: `Authorization` = `Bearer <token>`
   - Anfragetext: Datei → die Aufnahme aus Schritt 1
3. *Wörterbuchwert abrufen* → Schlüssel `text`
4. *In die Zwischenablage kopieren*

Danach im Zielfeld — etwa in Firefox — halten und einsetzen.

**„Diktat unterwegs"**

1. *Text diktieren* (Apples Erkennung, läuft ohne Netz)
2. *In die Zwischenablage kopieren*

Wer beides in einem Kurzbefehl will, kann über *Netzwerkdetails → Name des
WLAN-Netzwerks* verzweigen: im Heimnetz den Mac benutzen, sonst Apples Diktat.
Kurzbefehle kennen keine Fehlerbehandlung — deshalb entscheidet die Verzweigung
vorher, statt sich auf einen fehlgeschlagenen Aufruf zu verlassen.

## Gemessene Werte (2026-07-29, M3, Aufnahme von ~18 s)

| Weg | Spracherkennung | Bereinigung | gesamt |
|---|---|---|---|
| erste Anfrage, Modelle kalt | 7,4 s | 9,2 s | 16,7 s |
| Modelle warm | 0,9–1,2 s | 0,4–1,5 s | 1,6–2,7 s |

Das Vorwärmen der Bereinigung, das Stille Post ohnehin betreibt, wirkt also auch
für das iPhone. Die Übertragung selbst fällt nicht auf: 18 s Aufnahme sind als
AAC rund 76 kB.

## Prüfen ohne iPhone

```bash
say -v Anna -o probe.aiff "Also ähm, ein Test."
afconvert -f m4af -d aac -b 64000 probe.aiff probe.m4a
curl -s -H "Authorization: Bearer <token>" \
     --data-binary @probe.m4a http://127.0.0.1:8188/v1/dictate
```

Das prüft genau den Weg, den der Kurzbefehl nimmt — inklusive der Umwandlung von
AAC nach 16 kHz mono.
