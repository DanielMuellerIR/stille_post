# Changelog

Produktgeschichte von Stille Post. Format nach
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), Versionierung nach
[Semantic Versioning](https://semver.org/lang/de/).

Diese Datei wurde am 2026-07-16 nachträglich aus den Commit-Messages
rekonstruiert (0.6.2 bis 0.8.1). Die ausführliche Begründung jeder Entscheidung —
Messwerte, verworfene Alternativen, Fallstricke — steht im jeweils genannten
Commit; hier steht nur, was sich für den Nutzer geändert hat. Ab 0.8.2 wird die
Datei mit dem Versions-Bump fortgeschrieben.

## [0.9.16] — unveröffentlicht

### Behoben

- Das Verlaufsfenster liest und leert den Verlauf jetzt außerhalb des
  Main-Threads. Ein paralleler CLI-Zugriff oder das Löschen vieler Aufnahmen
  blockiert dadurch weder Fenster noch Menüleiste.
- Ein fertig transkribiertes Diktat wird auch dann ausgeliefert, wenn nur das
  abschließende Entfernen eines bereits überflüssigen WAV-Verweises im Verlauf
  nicht gespeichert werden kann; der Fehler bleibt sichtbar.

## [0.9.15] — unveröffentlicht

### Behoben

- Netzwerk-Brücke: Vollständig eingelesene Anfragen belegen das gemeinsame
  Speicherbudget jetzt bis zum Ende ihrer Verarbeitung. Wartende Diktate können
  dadurch nicht mehr neben weiteren Teilanfragen ein zweites Body-Budget belegen.
- Modell-Installation: App und CLI folgen beim Schreiben einer Download-
  Teildatei keinem Symlink mehr. Typ, Größe, Wiederaufnahme und Schreiben werden
  über denselben geprüften Dateideskriptor ausgeführt.
- `stillepost-cli set-cleanup-key` bricht jetzt vor dem Lesen ab, wenn ein
  Terminal seine Eingabeanzeige nicht sicher abschalten kann. Der API-Schlüssel
  kann in diesem Fehlerfall nicht mehr sichtbar im Scrollback landen.
- Diktat und Verlauf speichern den WAV-Verweis jetzt vor jedem Löschversuch und
  entfernen ihn erst nach bestätigtem Löschen. Ein zweiter Schreibfehler,
  paralleles Leeren des Verlaufs oder das Beenden in einem Fehlerzustand kann
  dadurch keine vorhandene Diagnoseaufnahme mehr unauffindbar machen.
- Das Ende eines Diktats wartet nicht mehr auf Verlaufssperren und Dateioperationen
  auf dem Main-Thread; Menüleiste, Overlay und Einstellungen bleiben dabei bedienbar.
- Der Datenschutzbefehl „Alle löschen“ schreibt vor dem ersten Dateilöschen
  textfreie Verweise auf alle eigenen Aufnahmen. Auch ein Prozessabbruch oder
  zweiter Schreibfehler lässt damit keinen unbekannten WAV-Rest zurück.
- Das Release-Skript gibt seine Laufsperre jetzt vor dem Entfernen der
  Signal-Handler frei. Ein Signal im Abschlussfenster kann Folge-Releases nicht
  mehr mit einer veralteten Sperre blockieren.

## [0.9.14] — unveröffentlicht

### Geändert

- `stillepost-cli` prüft die vollständige Befehlsform jetzt vor dem Laden der
  Konfiguration. Unbekannte oder zusätzliche Optionen werden mit Exit-Code 2
  abgewiesen, bevor der Befehl Verlauf, Schlüsselbund, Netz oder Server berührt.
- `stillepost-cli doctor` zählt bei ausgeschaltetem Whisper-Selbststart nur den
  nicht erreichbaren Server als Problem. Fehlendes Binary und Modell werden in
  dieser Konfiguration nicht benutzt und deshalb nicht als weitere Fehler
  ausgegeben.

### Behoben

- Bereinigung: Cloud- und Ollama-Endpunkte akzeptieren nur noch vollständige
  HTTP- oder HTTPS-Adressen ohne Zugangsdaten, Query oder Fragment. Ein
  abschließender Schrägstrich erzeugt außerdem keinen doppelten Pfadtrenner mehr.
- Diktat: Enthält eine Aufnahme nur Stille und lässt sich ihre WAV-Datei nicht
  löschen, bleibt ihr Name jetzt in einem textfreien Fehler-Eintrag im Verlauf
  erreichbar. Bisher lag der einzige Verweis im Arbeitsspeicher und ging beim
  nächsten Diktat oder Neustart verloren.
- Whisper: Verzeichnisse und Spezialdateien am Modellpfad gelten nicht mehr als
  installiertes Modell. App und CLI bieten dadurch wieder die Installation an,
  die den ungeeigneten Zieltyp mit einer konkreten Fehlermeldung abweist.
- Whisper: Die lokale Serveradresse lehnt Port 0 sowie Werte über 65535 ab,
  bevor sie an URLSession oder den Selbststart weitergereicht werden.
- `scripts/install-model.sh` prüft Ziel und Teildatei vor dem Download und erneut
  vor dem Verschieben. Das Skript folgt keinem Symlink auf ein Verzeichnis mehr
  und kann über einen Teildatei-Symlink keine fremde Datei überschreiben.
- `stillepost-cli set-cleanup-key` installiert seine Abbruchbehandlung jetzt vor
  dem Abschalten der Terminal-Anzeige und nimmt sie zurück, falls das Terminal
  die Umschaltung ablehnt. Ein Abbruchfenster mit dauerhaft stummer Eingabe ist
  damit geschlossen.

## [0.9.13] — unveröffentlicht

### Geändert

- `stillepost-cli doctor` prüft die Bereinigungs-Endpunkte jetzt über dieselbe
  Stelle im Kern, die auch die Bereinigung selbst benutzt — inklusive des Baus
  der Cloud-Adresse. Die Diagnose kann dadurch nicht mehr nach anderen Regeln
  urteilen als der Betrieb.
- `stillepost-cli doctor` prüft whisper-server jetzt in derselben Reihenfolge wie
  der Betrieb: Erst zählt, ob der Server antwortet. Läuft er, sind fehlendes
  Binary oder Modell kein Problem mehr, sondern ein Hinweis für den nächsten
  Kaltstart; läuft er nicht und ist `whisper.autostart` aus, ist das jetzt ein
  gemeldetes Problem statt einer Entwarnung.
- Ein Ollama-Modell gilt nur noch dann als vorhanden, wenn der Name exakt
  stimmt — plus dem einen Alias, den Ollama selbst definiert: Ein eingestellter
  Name ohne Tag meint `:latest`. Vorher passte zu `gemma4` jeder beliebige
  installierte Tag, und die Diagnose meldete „bereit“ für ein Modell, das der
  spätere Bereinigungs-Request gar nicht kennt.

### Behoben

- Sicherheit: Der über `stillepost-cli set-cleanup-key` eingetippte API-Schlüssel
  wird im Terminal nicht mehr angezeigt. Die Aufforderung verspricht das seit
  jeher, die Eingabe lief aber mit normaler Anzeige — der Schlüssel stand danach
  im Scrollback. Die Anzeige wird auch nach Abbruch mit Ctrl-C wieder
  eingeschaltet; eine Eingabe aus einer Pipe funktioniert unverändert.
- Modell-Installation: Zeigt `whisper.modelPath` versehentlich auf ein
  Verzeichnis, bricht die Installation jetzt ab, statt dessen Inhalt zu löschen
  und das Verzeichnis durch die Modelldatei zu ersetzen. Geprüft wird vor dem
  Download, und ein gescheitertes Aufräumen am Zielpfad wird gemeldet statt
  verschluckt.
- Release-Skript: Zwei gleichzeitige `./release.sh`-Läufe im selben
  Arbeitsverzeichnis schließen sich jetzt über eine Sperre aus. Beide benutzten
  dieselben Pfade unter `build/`; ein zweiter Lauf konnte dem ersten das DMG
  nach der Prüfung austauschen, sodass ein ungeprüftes Artefakt samt frisch
  berechneter Prüfsumme veröffentlicht wurde.
- Diktat: Ein Abbruch während der Verarbeitung löscht jetzt auch die fertige
  Aufnahme. Bisher kannte sie nach dem Stoppen niemand mehr — der Verlauf
  bekommt bei einem Abbruch keinen Eintrag —, und eine vollständige Aufnahme
  blieb unauffindbar auf der Platte liegen.
- Diktat: Lässt sich die Aufnahme nach einem erfolgreichen Diktat nicht löschen,
  wird ihr Name jetzt im Verlaufseintrag nachgetragen. Ohne diesen Verweis fand
  „Alle löschen“ sie später nicht mehr. Dasselbe gilt für „Erneut
  transkribieren“, wenn dort das Löschen scheitert.
- Diktat: Die Nachverarbeitung läuft jetzt vollständig auf dem Hauptthread. Sie
  las und schrieb dieselben Felder (Zustand, Sitzungsnummer), die Start, Stopp
  und Abbruch dort anfassen; ein alter Lauf konnte deshalb den Zustand eines
  neuen überschreiben oder trotz Abbruch noch ausliefern. Die eigentliche
  Bereinigung läuft weiterhin außerhalb des Hauptthreads.
- Diktat: Ein verspätet fertig gewordenes Segment kann nicht mehr in der
  Sammlung einer bereits neu begonnenen Aufnahme landen.
- Verlauf: Lässt sich beim „Alle löschen“ eine Aufnahme nicht löschen (Rechte,
  gesperrte Datei), bleibt jetzt ein Platzhalter mit ihrem Dateinamen stehen —
  ohne den gelöschten Text. Bisher war der Verweis weg, und ein zweiter Klick
  fand die Datei nicht mehr.
- Netzwerk-Brücke: Alle Verbindungen zusammen dürfen nur noch so viele
  Anfrage-Bytes puffern, wie die Warteschlange überhaupt annimmt. Acht offene
  Verbindungen konnten vorher acht vollständige Bodys gleichzeitig im Speicher
  halten, obwohl fünf davon anschließend nur ein 503 bekommen hätten. Ein
  vollständig gelesener Inhalt wird außerdem nicht mehr doppelt gehalten.
- Netzwerk-Brücke: Ein Kopf an der Größengrenze wird nicht mehr abgelehnt, nur
  weil die vier Trennbytes zwischen Kopf und Inhalt in zwei Paketen ankamen.
- Modell-Download: Eine fortgesetzte Übertragung wird nur noch angenommen, wenn
  der Server genau den angeforderten Bereich derselben Datei liefert
  (`Content-Range` mit passendem Startversatz und passender Gesamtgröße).
- `scripts/install-model.sh`: Eine angefangene Datei, die größer ist als das
  Modell heute, wird verworfen statt fortgesetzt. Sonst forderte `curl` einen
  Versatz hinter dem Dateiende an und scheiterte bei jedem weiteren Versuch —
  derselbe Dauerblocker, der in App und CLI schon behoben war.
- Verlauf: „Alle löschen“ räumt jetzt jede zurückbehaltene Aufnahme weg, auch
  wenn eine davon nicht zu löschen ist. Bisher brach der Vorgang beim ersten
  Problem ab; der Verlauf war zu diesem Zeitpunkt schon leer, und alle weiteren
  Aufnahmen blieben ohne zugehörigen Eintrag auf der Platte liegen. Ein
  aufgetretener Fehler wird weiterhin gemeldet.
- Diktat: Lässt sich die temporäre Aufnahme nach einem erfolgreichen Diktat
  nicht löschen, wird der fertige Text jetzt trotzdem eingefügt und erst danach
  der Fehler gemeldet. Bisher hielt das gescheiterte Aufräumen das gesamte
  Diktat zurück, obwohl es längst bereinigt und im Verlauf gespeichert war.
- Modell-Download: Eine Teildatei, die größer ist als die erwartete Datei, wird
  nicht mehr als angefangener Download weiterverwendet, sondern neu geladen.
  Wurde das Modell am Server durch eine kleinere Fassung ersetzt, blieb die
  Installation sonst dauerhaft mit der Meldung über eine unvollständige Datei
  stehen, bis jemand die Teildatei von Hand löschte.
- Netzwerk-Brücke: Die Herkunftsprüfung entscheidet jetzt anhand der 16 Bytes
  einer Adresse statt anhand ihrer Schreibweise. Eine IPv6-Adresse darf ihre
  letzten vier Bytes mit Punkten schreiben („2a00:1234::192.168.1.1“ ist eine
  gültige globale Adresse); bisher galt so eine Adresse aus dem Internet wegen
  der Punkte als privates IPv4-Netz und kam an der ersten Hürde vorbei — das
  Token schützte weiterhin. Umgekehrt zählt eine eingebettete private
  IPv4-Adresse nun in beiden Schreibweisen als Heimnetz.
- Bereinigung: Das erste Diktat nach einem Kaltstart verliert die Bereinigung
  nicht mehr. Lädt der Ollama-Server das Modell gerade erst, schweigt er länger
  als die 10 s Geduld des Streaming-Pfads (gemessen: 11,5 s für das 6-GB-Modell);
  bisher lief auch der zweite Versuch als Stream in dasselbe Timeout, und das
  Diktat fiel auf einen Ausweich-Endpunkt oder den Rohtext zurück. Jetzt klärt
  eine schnelle Probe, ob der Server lebt: dann wartet der zweite Versuch geduldig
  auf die vollständige Antwort. Ist der Server wirklich weg, zieht die Kette
  sofort weiter, statt weitere 10 s zu verschenken.

## [0.9.12] — 2026-08-16

### Behoben

- Netzwerk-Brücke: Schließt ein Client die Verbindung erst nach einer vollständig
  übertragenen Anfrage, wird die laufende oder wartende Arbeit jetzt trotzdem
  storniert. Bisher wurde nach dem Einlesen nicht weiter auf das Verbindungsende
  geachtet; Transkription und Bereinigung konnten daher für niemanden weiterlaufen.
- Bereinigung: Eine gelöschte Verneinung wird auch dann dem richtigen Satzteil
  zugeordnet, wenn in derselben Löschungslücke ein Füllwort hinter der Satzgrenze
  steht. Englische n't-Kurzformen zählen außerdem genau einmal als Verneinung;
  gleichbedeutende Erweiterungen wie „didn't“ zu „did not“ bleiben damit erlaubt.
- Netzwerk-Brücke: Unicode-Steuerzeichen sowie Zeilen- und Absatztrenner können
  keine zusätzlichen sichtbaren Zeilen mehr in `bridge.log` oder die
  CLI-Diagnose einschleusen. Die Request-Line akzeptiert nur das unterstützte
  ASCII-Format, und die zweite Log-Schranke maskiert die übrigen Aufrufwege.
- Release-Skript: Ein Signal direkt nach dem Hardlink der Prüfsumme wird jetzt
  auch vor dem anschließenden Shell-Marker als eigenes, unvollständiges Artefakt
  erkannt und zurückgerollt. Eine einzelne `.sha256` blockiert dadurch keinen
  Wiederholungsversuch mehr.
- Einstellungen: Während ein API-Schlüssel asynchron gespeichert wird, bleibt
  auch das Eingabefeld gesperrt. Sein Inhalt wird nach Erfolg nur gelöscht, wenn
  er noch genau dem gespeicherten Schnappschuss entspricht.

## [0.9.11] — 2026-08-15

### Behoben

- Netzwerk-Brücke: Bricht ein Gerät die Verbindung ab, während seine Anfrage
  noch in der Warteschlange steht, wird sie jetzt verworfen, statt Transkription
  und Bereinigung für ein Ergebnis laufen zu lassen, das niemand mehr abholt.
  Bisher belegte ein Client, der einfach auflegte, den einzigen Arbeitsplatz der
  Brücke bis zum Ende weiter.
- Netzwerk-Brücke: Das Ende der Warteschlange hielt nach getaner Arbeit die
  fertige Antwort der letzten Anfrage fest — bei `/v1/dictate` also den
  vollständigen diktierten Text. Er blieb dadurch bis zur nächsten Anfrage im
  Speicher stehen und wird jetzt sofort freigegeben.
- Netzwerk-Brücke: Auch die Protokollzeilen für eine abgewiesene Gegenstelle und
  für einen Lese-Timeout maskieren die Adresse jetzt einzeilig. Bisher galt das
  nur für die Zeile einer angenommenen Anfrage.
- Einstellungen: „Im Schlüsselbund speichern“ arbeitet jetzt abseits des
  Haupt-Threads, genau wie die Prüfung daneben und wie die Token-Knöpfe der
  Brücke. Zeigt macOS beim Speichern einen Berechtigungsdialog, blockiert er
  nicht mehr das Einstellungsfenster. Beide Knöpfe sind währenddessen gesperrt,
  damit Speichern und Prüfen sich nicht überholen.
- `stillepost-cli doctor` stürzt nicht mehr ab, wenn in der Konfiguration eine
  unbrauchbare Ollama-Adresse steht (etwa mit Leerzeichen im Hostnamen). Der
  Befund wird jetzt wie ein nicht erreichbarer Endpunkt gemeldet — ausgerechnet
  dieser Befehl wird wegen einer kaputten Konfiguration aufgerufen. Außerdem
  bricht die Erreichbarkeitsprüfung nach fünf Sekunden ab statt nach einer
  Minute; `doctor` prüft die ganze Kette, und ein abgeschalteter Rechner soll
  nicht jedes Mal so lange kosten.
- Diktat-Ablauf: Bricht das Stoppen an einer internen Prüfung ab, geht die
  Maschine zurück auf „bereit“ statt dauerhaft in „verarbeitet“ stehen zu
  bleiben. In diesem Zustand ignoriert der Hotkey jeden Tastendruck — die App
  wäre bis zum Neustart taub gewesen. Der Fall ist mit dem heutigen Ablauf nicht
  auslösbar; die Sackgasse ist trotzdem weg.
- Verlauf: Der gespeicherte Name einer zurückbehaltenen Aufnahme wird jetzt auch
  beim Lesen geprüft und nicht nur beim Löschen. Ein Name, der aus dem
  Aufnahme-Ordner herausführt, ergibt keinen Lesepfad mehr — „Erneut
  transkribieren“ hätte sonst eine beliebige Datei an den whisper-server
  geschickt.
- Modell-Download: Die Teildatei eines abgebrochenen Downloads trägt jetzt den
  Modellnamen. Beide angebotenen Modelle landen im selben konfigurierten
  Zielpfad; bisher hieß die Teildatei nur `<ziel>.partial`, und ein Wechsel des
  Modells setzte den abgebrochenen Download des anderen fort. Am Ende stimmte
  die Gesamtgröße, und die Vollständigkeitsprüfung ließ eine aus zwei Modellen
  zusammengesetzte Datei durch. Eine alte `<ziel>.partial` aus einem früheren
  Abbruch wird nicht mehr fortgesetzt und kann von Hand gelöscht werden.
- Bereinigung: Ein Fehlertext, den der LLM-Dienst im Stream meldet, wird wie
  jede andere fremde Fehlerantwort auf 300 Zeichen gekürzt, bevor er als Grund
  in den Verlauf geschrieben wird. Bisher landete er dort in voller Länge — ein
  einziger fehlerhafter Dienst konnte damit die gesamte Verlaufsdatei füllen.

## [0.9.10] — 2026-08-11

### Behoben

- Bereinigung: Englische Verneinungen mit geradem oder typografischem Apostroph
  schützen auch das einzelne Schluss-`t`; aus „can't“ kann damit nicht mehr
  unbemerkt „can“ werden. Liegen Füllwort, Satzgrenze und gelöschte Verneinung
  in derselben Ausrichtungslücke, wird die Verneinung jetzt ihrem tatsächlichen
  Satzteil zugeordnet.
- Netzwerk-Brücke: C0-/DEL-Steuerzeichen in der HTTP-Request-Line werden
  abgelehnt. Methode, Pfad und Gegenstellen-Adresse werden zusätzlich
  einzeilig maskiert, bevor sie in `bridge.log` oder die CLI-Diagnose gelangen.
- `stillepost-cli bridge token` liest den Tokenzustand ohne `--new` genau einmal
  und erzeugt nach einem Lesefehler unter keinen Umständen einen Ersatz-Token.
- Release-Skripte: `INT` und `TERM` rollen ein noch unvollständiges eigenes
  Artefaktpaar zurück und enden mit Fehlerstatus. Ein Signal im Übergang zum
  vollständigen DMG-/Prüfsummenpaar kann nicht mehr nur eine Hälfte entfernen
  und anschließend Erfolg melden.
- Die öffentlichen Datenschutztexte beschreiben globale IPv6-Adressen im
  lokalen Schnittstellenpräfix korrekt. Die Health-Antwort dokumentiert keinen
  veralteten festen Versionswert mehr.

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
