# Changelog

Produktgeschichte von Stille Post. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei wurde am 2026-07-16 nachträglich aus den Commit-Messages
rekonstruiert (0.6.2 bis 0.8.1). Die ausführliche Begründung jeder Entscheidung —
Messwerte, verworfene Alternativen, Fallstricke — steht im jeweils genannten
Commit; hier steht nur, was sich für den Nutzer geändert hat. Ab 0.8.2 wird die
Datei mit dem Versions-Bump fortgeschrieben.

## [0.9.9] — 2026-08-10

### Hinzugefügt

- Netzwerk-Brücke: Die Protokollzeilen stehen jetzt in `bridge.log` neben
  `config.json` — mit Zeitstempel, und ein fehlgeschlagener Start samt Grund
  gehört dazu. Bisher gingen sie nur nach stderr, und das landet bei einer aus
  dem Finder gestarteten App nirgends: „Vom iPhone kommt nichts an“ war damit
  von außen nicht nachvollziehbar. Ab 1 MB wird einmal nach `bridge.log.1`
  weggeräumt. Diktattext und Token stehen weiterhin nicht darin.

### Behoben

- Netzwerk-Brücke: Eine abgewiesene Anfrage nennt im lokalen Protokoll den
  Grund — kein Token geschickt, Token stimmt nicht, oder auf diesem Mac ist
  keins angelegt. Bisher stand dort nur „401“, obwohl der Code das Gegenteil
  behauptete. Die HTTP-Antwort bleibt unverändert dieselbe knappe `401`.

## [0.9.8] — 2026-08-10

### Behoben

- Netzwerk-Brücke: Ein iPhone, das über IPv6 ankommt, wird nicht mehr abgewiesen.
  Die FRITZ!Box gibt allen Geräten im Haus Adressen aus demselben globalen
  Präfix; solche Adressen sehen öffentlich aus, gehören aber zum eigenen Netz.
  Bisher galt nur ein privater Adressbereich als Heimnetz, und die Verbindung
  wurde noch vor der Token-Prüfung lautlos abgeschnitten — auf dem iPhone kam
  einfach nichts zurück. Jetzt zählt eine globale IPv6-Adresse als Heimnetz, wenn
  sie im selben Netzbereich liegt wie eine Adresse dieses Macs. Ein Gegenüber aus
  dem Internet hat ein anderes Präfix und fällt weiterhin durch.

## [0.9.7] — 2026-08-10

### Behoben

- Netzwerk-Brücke: Ein Schlüsselbund-Fehler wird nicht mehr als „Kein
  Brücken-Token vorhanden“ gemeldet. Bisher ergaben „noch keins angelegt“ und
  „nicht lesbar“ (gesperrter Schlüsselbund, verweigerter Zugriff, kaputter
  Eintrag) dieselbe Meldung — der Hinweis schickte den Nutzer dann zum Anlegen
  eines neuen Tokens, obwohl das alte womöglich noch da ist und ein neues alle
  eingerichteten Geräte aussperren würde. App, Startmeldung und
  `stillepost-cli bridge status` nennen jetzt den Schlüsselbund-Status.
- Netzwerk-Brücke: `stillepost-cli bridge token` und der Token-Knopf in den
  Einstellungen brechen bei einem Lesefehler ab, statt ersatzweise ein neues
  Token anzulegen und damit ein möglicherweise vorhandenes zu überschreiben.
- Fehlermeldungen mit OSStatus zeigen den Code wieder unverfälscht: Mit
  deutscher Sprache machte die Formatierung aus `-25308` die Zahl „-25.308“.

## [0.9.6] — 2026-08-07

### Behoben

- Bereinigung, Worttreue: Eine stark gekürzte Ausgabe kann sich nicht mehr an
  späten Wortwiederholungen festhalten. Kamen dieselben Wörter mehrfach im
  Diktat vor, richtete die Prüfung die Ausgabe unter Umständen an den SPÄTEN
  Vorkommen aus; der ganze Anfang galt dann als erlaubte Löschung. Jetzt gewinnt
  bei Gleichstand die früheste Ausrichtung.
- Bereinigung, Worttreue: Eine wortlose Ausgabe („kein“ → „.“) wird verworfen,
  solange der Rohtext überhaupt Wörter enthielt. Bisher rutschte sie durch, weil
  für kurze Eingaben ein weiter Längenkorridor gilt.
- Bereinigung, Verneinungen: Lässt das Modell eine Verneinung weg, geht jetzt
  der Satzteil zurück, zu dem sie im Diktat gehörte. Stand sie hinter einem
  Punkt oder Komma, wurde bisher der davorstehende — unveränderte — Satz
  zurückgesetzt, und die Verneinung hing als Rest an dessen Ende.
- Bereinigung, Verneinungen: Die Liste geschützter Wörter kennt jetzt auch
  Englisch (not, no, none, never, nothing, nobody, nowhere, neither, nor,
  without, only, cannot samt verkürzten Formen wie „didn’t“). Bei englischem
  Diktat konnte aus „I did not approve this“ bisher „I did approve this.“
  werden.
- Netzwerk-Brücke: Die Warteschlange der schweren Routen hat eine Obergrenze.
  Mehr gleichzeitige Diktate als die Grenze werden mit 503 abgelehnt, statt
  samt Audio-Body im Speicher zu warten.
- Netzwerk-Brücke: Der Lese-Timeout wird mit jeder Antwort storniert. Nach einer
  abgewiesenen Anfrage (401) hielt sein Zeitgeber die Verbindung bisher noch bis
  zu 30 Sekunden fest und protokollierte am Ende einen Lese-Timeout, den es nie
  gab.
- Audio-Decoder: Eine gelogene Container-Länge kann die Vorausschau auf die
  Zielgröße nicht mehr überlaufen lassen. Die Kappung passiert jetzt vor der
  Umwandlung in eine Ganzzahl; zu langes Audio wird wie vorgesehen als „zu lang“
  gemeldet, statt den Prozess zu beenden.
- Release-Skripte: Die Veröffentlichung nutzt `link` statt `ln` — steht am
  Zielpfad inzwischen ein Verzeichnis, scheitert sie jetzt, statt die Datei
  darin abzulegen und Erfolg zu melden. Die Prüfsumme wird nicht mehr in einen
  vorgefundenen Symlink geschrieben, und ein Abbruch zwischen Prüfsumme und DMG
  lässt keine verwaiste `.sha256` zurück.
- Release-Prüfung: Die erwartete Developer-Team-ID kommt aus `DEVELOPER_TEAM_ID`
  oder `git config stillePost.teamId` statt aus der gerade gebauten App. Vorher
  prüfte das Release sich gegen sich selbst — eine vollständig mit der falschen
  Identität signierte App wäre durchgegangen.

## [0.9.5] — 2026-08-03

### Behoben

- Bereinigung: Eine verschluckte Verneinung zählt jetzt genauso wie eine
  ersetzte. Der Schutz aus 0.9.4 griff nur, wenn das Modell ein sinntragendes
  Wort AUSTAUSCHTE. Ließ es das Wort ersatzlos weg, sah der Abgleich nur eine
  Löschung — und Löschungen sind als Füllwort-Entfernung erlaubt. Aus „ich habe
  das nicht gemacht“ konnte so „Ich habe das gemacht.“ werden. Fällt eines der
  geschützten Wörter (kein, nicht, nie, niemand, nirgends, nein, ohne, weder,
  nur, mehr, immer samt Formen) weg, geht der betroffene Satzteil jetzt auf das
  Diktierte zurück. Füllwörter dürfen weiterhin verschwinden, und eine
  gestotterte Verneinung („nicht nicht“) darf weiterhin entdoppelt werden, weil
  das Wort daneben stehen bleibt.

## [0.9.4] — 2026-08-03

### Behoben

- Bereinigung: Verneinungen und andere sinntragende Funktionswörter dürfen nicht
  mehr „korrigiert“ werden. Die Toleranz für einen einzelnen Verhörer ist so
  weit, dass „ich habe kein Problem“ zu „ich habe ein Problem“ werden konnte —
  ein Buchstabe Unterschied, aber die gegenteilige Aussage. Für eine Liste von
  Verneinungs- und Reichweitenwörtern (kein, nicht, nie, niemand, nirgends,
  nein, ohne, weder, nur, mehr, immer samt Formen) fällt der betroffene Satzteil
  jetzt auf das Diktierte zurück. Die reine Beugung bleibt erlaubt („kein“ →
  „keinen“), ebenso alle übrigen Verhörer-Korrekturen.
- Rohtext-Reparatur: Gängige deutsche Abkürzungen behalten ihren Punkt. Fällt
  die Bereinigung aus, macht die deterministische Nachstufe den Text lesbar —
  aus „Das gilt ggf. auch“ wurde dabei bisher „Das gilt ggf, auch“. Kürzel wie
  ggf., bzw., usw., inkl., vgl. oder evtl. sind jetzt geschützt.

## [0.9.3] — 2026-08-02

### Behoben

- Datenschutz: Der Whisper-Client folgt keinen HTTP-Weiterleitungen mehr. Einer
  307/308-Antwort des lokalen whisper-servers wäre URLSession bisher samt
  komplettem Audio-Body zum ungeprüften Host aus dem `Location`-Kopf gefolgt —
  jetzt wird jede Weiterleitung abgelehnt und als Serverfehler gemeldet.
- Netzwerk-Brücke: Ein falsches oder fehlendes Token wird direkt nach dem
  HTTP-Kopf abgewiesen, bevor die Brücke den (bis zu mehrere MB großen) Body
  puffert. Beendete Verbindungen geben Session und Puffer wieder frei (ein
  Referenzzyklus hielt sie bisher dauerhaft im Speicher). `start()` bestätigt
  den Start erst, wenn der Port wirklich lauscht — ein belegter Port ist jetzt
  ein Fehler, statt dass App und CLI „gestartet“ melden, ohne erreichbar zu
  sein. Gleichzeitige Anfragen laufen garantiert nacheinander durch Whisper und
  Bereinigung. Die Puffer-Obergrenze zählt die vier Trennbytes zwischen Kopf
  und Body mit (exakt maximale gültige Anfragen wurden fälschlich abgewiesen),
  und der Router erzwingt die Größengrenze zusätzlich selbst.
- Bereinigung: Die Worttreue-Prüfung rechnet die Wort-Ausrichtung mit linearem
  Speicher (Hirschberg-Verfahren) statt einer vollen Tabelle — bei
  Mehrtausend-Wort-Diktaten kostete die bisher Hunderte MB. Zurückgesetzte
  Satzteile übernehmen wieder den Original-Wortlaut samt Binde- und
  Schrägstrichen („CI/CD-Workflow“ zerfiel zuvor zu „CI CD Workflow“).
- Audio-Umwandlung der Brücke: Ein Lesefehler mitten in der Datei bricht die
  Transkription ab, statt still abgeschnittenes Audio als Erfolg zu liefern.
  Dekodiertes Audio ist auf eine Stunde begrenzt, damit manipulierte oder
  extrem komprimierte Dateien den Speicher nicht sprengen.
- Whisper-Autostart bindet den Server an die konfigurierte Loopback-Adresse
  (etwa `http://[::1]:9090` oder eine andere 127er-Adresse) statt stur an
  `127.0.0.1` — solche gültigen Konfigurationen liefen sonst in den
  Start-Timeout.
- Schlüsselbund: Brücken-Token und Cleanup-API-Key werden aktualisiert statt
  „löschen, dann neu anlegen“ — ein Fehler beim Anlegen konnte bisher den
  alten, gültigen Wert vernichten und alle eingerichteten Geräte aussperren.
  In den Einstellungen sind „Token kopieren“/„Neues Token“ während einer
  laufenden Schlüsselbund-Aktion gesperrt, damit kein veraltetes Token in der
  Zwischenablage landet.
- Build-/Release-Skripte: `./build.sh` lehnt Argumente ab und kann damit nicht
  mehr versehentlich notarisieren oder installieren. `verify-release.sh` prüft
  die Team-ID aller eingebetteten Binaries und Frameworks einzeln (CLI, Sparkle
  samt Autoupdate und Updater). DMG und Prüfsumme werden atomar und garantiert
  ohne Überschreiben veröffentlicht.

## [0.9.2] — 2026-07-29

### Hinzugefügt

- Diktat vom iPhone über das Heimnetz: Die App kann Aufnahmen von eigenen Geräten
  annehmen, transkribiert sie mit dem lokalen Whisper-Modell und gibt den
  bereinigten Text zurück. Auf dem iPhone genügt ein Kurzbefehl am Action-Button
  (aufnehmen → senden → Text in die Zwischenablage), es braucht keine App und
  keine eigene Tastatur. Drei Routen: `GET /v1/health`, `POST /v1/dictate`
  (Audio → fertiger Text, `?raw=1` ohne Bereinigung) und `POST /v1/cleanup`
  (Rohtext → bereinigter Text, für Geräte, die selbst transkribieren). Anleitung,
  Entscheidungen und Messwerte in `docs/ios-bridge.md`.
- Der Zugang ist standardmäßig aus, verlangt ein Token aus dem Schlüsselbund und
  nimmt nur Verbindungen aus privaten Adressbereichen an. Einzuschalten in den
  Einstellungen unter „Allgemein" oder in `config.json` (`bridge`); das Token legt
  die App oder `stillepost-cli bridge token` in die Zwischenablage, angezeigt wird
  es nie.
- `stillepost-cli bridge status|token|serve` für Einrichtung und Diagnose ohne GUI.
- Eingehendes Audio darf in jedem gängigen Format kommen (AAC/m4a wie vom iPhone,
  MP3, WAV, FLAC); die App rechnet es auf die 16 kHz Mono um, die Whisper braucht.

### Wichtig zu wissen

- Die Verbindung im Heimnetz ist **unverschlüsselt**. Wer im gleichen WLAN
  mitliest, kann Diktate mitlesen. Die Einstellungen sagen das ausdrücklich;
  Verschlüsselung mit gemerktem Zertifikat braucht eine eigene iPhone-App und
  steht im Backlog.
- Die Datenschutzgrenze bleibt unverändert: Die App sendet weiterhin selbst nie
  Audio irgendwohin. Die Brücke ist reiner Empfänger, und die Spracherkennung läuft
  weiter ausschließlich über den lokalen whisper-server auf Loopback.

## [0.9.1] — 2026-07-24

### Geändert

- Menüleisten-Symbol im Ruhezustand von `mic` auf `waveform.and.mic` geändert:
  Das Kontrollzentrum zeigt bei Mikrofon-Nutzung (z. B. Videocall) ein fast
  identisches Mikrofon in der Menüleiste, wodurch Stille Post doppelt vorhanden
  wirkte. Das Verarbeitungs-Symbol wechselt passend von `waveform` auf
  `waveform.circle`, damit es sich vom neuen Ruhesymbol unterscheidet.

## [0.9.0] — 2026-07-24

### Hinzugefügt

- Deterministische Vorstufe vor der LLM-Bereinigung: Whisper-Zeilenumbruch-
  Artefakte werden regelbasiert entfernt — auch mitten im Wort zerrissene Wörter
  („Identitä⏎tsproblem") werden wieder zusammengefügt (Heuristik am echten
  Verlaufskorpus validiert: Umbrüche zwischen Wörtern tragen immer ein
  Leerzeichen). Läuft ohne LLM, also auch bei ausgeschalteter Bereinigung.
- Deterministische Nachstufe für Rohtext-Fallbacks und zurückgesetzte Satzteile:
  Punkt vor kleingeschriebenem Wort wird zum Komma (Segmentgrenzen-Artefakt;
  Abkürzungen, Zahlen und Auslassungspunkte bleiben geschützt), Großschreibung
  nach `!`/`?` und am Textanfang, gedoppelte Trennzeichen werden zusammengefasst.
  Ein Diktat ohne (erfolgreiche) LLM-Bereinigung kommt damit deutlich lesbarer an.
- Persönliches Fachbegriffs-Wörterbuch (`cleanup.dictionary` in `config.json`,
  mit generischer Vorbelegung): Die Begriffe gehen als bevorzugte Schreibweisen an
  das Bereinigungsmodell, und die Worttreue-Prüfung akzeptiert ähnlich klingende
  Korrekturen auf genau diese Begriffe („Mini Macs" → „MiniMax").
- Der Grund eines Bereinigungs-Fallbacks wird jetzt im Verlauf gespeichert
  (`cleanupFallbackReason`) und im Verlaufsfenster angezeigt — bisher ließ sich
  nur raten, ob ein Endpoint down war oder die Worttreue-Prüfung verworfen hat.

### Geändert

- Die Worttreue-Prüfung ist nicht mehr alles-oder-nichts: Statt bei einem einzigen
  veränderten Wort die komplette Bereinigung zu verwerfen (und damit alle korrekten
  Satzzeichen-Korrekturen mit), wird der Text an Satzzeichen in Satzteile zerlegt
  und nur der betroffene Satzteil auf die Roh-Wörter zurückgesetzt. Komplett
  verworfen wird weiterhin bei Markdown-Strukturen, gesprengtem Längenkorridor,
  überzogenem Korrektur-Budget oder mehr als der Hälfte betroffener Satzteile.
  Anlass: Am 2026-07-23 waren alle vier „Ausfälle" in Wahrheit Totalverwürfe wegen
  einzelner Wörter — die Endpoints hatten in 0,9–3,1 s geantwortet.
- Gleich klingende Wörter (Kölner Phonetik, ab 3 Buchstaben je Seite) gelten in
  der Worttreue-Prüfung als zulässige Hör-Korrektur („Rack" → „RAG") statt als
  verbotene Ersetzung.

## [0.8.14] — 2026-07-23

### Behoben

- Die ausgelieferte App fand ihr Lokalisierungs-Bundle nur auf der Build-Maschine
  und stürzte auf jedem anderen Rechner sofort beim Start ab (fataler Fehler in
  `Bundle.module`, noch vor dem Menüleisten-Icon). Ursache: der von SwiftPM
  generierte Zugriff sucht das Ressourcen-Bundle nur im `.app`-Wurzelverzeichnis
  oder unter dem fest einkompilierten Build-Pfad — nicht dort, wo
  `scripts/build-app.sh` es ablegt (`Contents/Resources`). `L10n` löst das Bundle
  jetzt selbst robust auf (Contents/Resources, neben dem Executable, `.app`-Wurzel;
  Fallback SwiftPM). Damit startet die App unabhängig von der Build-Maschine.
  0.8.13 war davon bereits betroffen — nur auf der Build-Maschine blieb es
  unbemerkt, weil dort der einkompilierte Build-Pfad zufällig existiert.

## [0.8.13] — 2026-07-23

### Behoben

- Notfall-Korrektur: 0.8.12 stürzte beim Abschluss des ersten Diktats ab — danach
  fehlten Menüleisten-Icon und Hotkey, die App war unbenutzbar. Ursache war die
  Übergabe des fertigen Diktats an die Oberfläche auf einem Hintergrund-Thread:
  `finishSession` läuft als `nonisolated async` bewusst abseits des Main-Threads,
  reichte das Ergebnis aber direkt an das Overlay (AppKit) weiter. Aktuelles macOS
  bricht AppKit-Zugriffe außerhalb des Main-Threads hart ab. Das fertige Ergebnis
  wird jetzt — wie schon die Zustands-Updates — garantiert auf dem Main-Thread an
  Overlay und Einfügen übergeben. Ein Kern-Test sichert diese Zusage dauerhaft ab.

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
