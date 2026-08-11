# Diktat vom iPhone über das Heimnetz

Stand: 2026-07-29 (Stufe 0 gebaut und am iPhone verifiziert: Aktionstaste →
Diktat → Text in der Zwischenablage, zwei Durchläufe).

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

- `GET /v1/health` → `{"ok":true,"version":"<App-Version>","cleanup":true}`.
  Im App-Bundle kommt der Wert aus dessen Produktversion; ein direkter CLI-Lauf
  ohne Bundle kann stattdessen `dev` melden.
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
  abgewiesen. Als Heimnetz gelten die privaten IPv4-Bereiche, Link-Local, IPv6-ULA
  — und eine globale IPv6-Adresse genau dann, wenn sie im selben Netzbereich liegt
  wie eine Adresse dieses Macs. Letzteres ist nötig, weil die FRITZ!Box allen
  Geräten im Haus Adressen aus demselben globalen Präfix gibt: Das iPhone kommt
  über IPv6 mit einer Adresse an, die öffentlich aussieht, aber zum eigenen Netz
  gehört. Bis 0.9.7 wurde genau die abgewiesen — und zwar lautlos, weil die
  Verbindung vor jeder Antwort abgeschnitten wird. Ein Gegenüber aus dem Internet
  hat ein anderes Präfix und fällt weiterhin durch; eine versehentliche
  Portweiterleitung stellt die Brücke also nach wie vor nicht ins Netz.
- Größengrenze je Anfrage (Standard 25 MB), Kopfzeilen-Grenze, Lesefrist von 30 s,
  höchstens acht gleichzeitige Verbindungen.
- Begrenzte Warteschlange für Diktat und Bereinigung: höchstens drei Anfragen
  gleichzeitig (eine läuft, zwei warten). Alles darüber beantwortet die Brücke
  sofort mit `503`, statt es samt Audio im Speicher zu puffern — die
  Größengrenze je Anfrage sagt nichts über deren Anzahl.
- Protokollzeilen enthalten Methode, Pfad, Status, Größe, Dauer und Gegenstelle —
  **nie** Diktattext und nie das Token. Sie stehen in `bridge.log` neben
  `config.json` (ab 1 MB wird einmal nach `bridge.log.1` weggeräumt) und
  zusätzlich auf stderr. Auch ein fehlgeschlagener Start steht dort, samt Grund.
  Bei einer abgewiesenen Anfrage nennt die Zeile, woran es lag: kein Token
  geschickt, Token stimmt nicht, oder auf diesem Mac ist keins angelegt. Die
  HTTP-Antwort bleibt in allen drei Fällen dieselbe knappe `401`, damit die
  Gegenseite daraus nichts über den Zustand des Macs lernt.

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
- iOS fragt beim ersten Zugriff nach der Berechtigung für das lokale Netzwerk
  (bestätigt am 2026-07-29: die Abfrage kommt beim ersten Lauf des Kurzbefehls).
- Wurde das Token mit `stillepost-cli bridge token` angelegt, verlangt macOS
  beim nächsten Start der App einmal eine Schlüsselbund-Freigabe, weil ein
  anderes Programm (die CLI) den Eintrag erzeugt hat. Bis zum Klick auf
  „Immer erlauben" lauscht die Brücke nicht — die App wartet still auf den
  Dialog. Wer die Brücke stattdessen komplett über die App-Einstellungen
  einrichtet, umgeht das.

## Der Kurzbefehl auf dem iPhone

Zwei getrennte Kurzbefehle sind einfacher als einer mit Sonderfällen. Der erste
gehört auf den Action-Button.

**„Diktat" (zu Hause, volle Qualität)**

1. *Audio aufnehmen* — Start: sofort, Stoppen: beim Antippen.
2. *Inhalte von URL abrufen* — die Optionen sind hinter dem blauen Pfeil
   eingeklappt:
   - URL: `http://<mac-name>.local:8188/v1/dictate`
   - Methode: `POST`
   - Header: Schlüssel `Authorization`, Wert `Bearer <token>`. Das Wort
     `Bearer` samt Leerzeichen gehört mit in den Wert; nur das Token genügt
     nicht (die Brücke antwortet dann 401).
   - Anfragetext: von `JSON` auf `Datei` umstellen und die Variable
     *Aufgenommenes Audio* wählen. Bleibt `JSON` stehen, geht die Anfrage
     **ohne** die Aufnahme raus und die Brücke antwortet 400.
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

Der erste echte iPhone-Durchlauf (2026-07-29, Aktionstaste, Modelle warm)
bestätigt das: 158 kB Aufnahme, 3,85 s vom Eintreffen der Anfrage bis zur
Antwort — gemessen am Protokoll der Brücke.

## Prüfen ohne iPhone

```bash
say -v Anna -o probe.aiff "Also ähm, ein Test."
afconvert -f m4af -d aac -b 64000 probe.aiff probe.m4a
curl -s -H "Authorization: Bearer <token>" \
     --data-binary @probe.m4a http://127.0.0.1:8188/v1/dictate
```

Das prüft genau den Weg, den der Kurzbefehl nimmt — inklusive der Umwandlung von
AAC nach 16 kHz mono.
