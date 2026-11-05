# Linux-Parität: verbindlicher Abgleich zur Mac-App

Arbeitsstand 2026-11-05. Referenz ist die vorhandene macOS-App im selben
Quellstand, nicht die reduzierte Linux-Oberfläche von 0.9.47. „Geprüft“ erfordert
beobachtetes Verhalten auf beiden Ziel-Desktops; ein Build allein genügt nicht.

| Bereich | Mac-Vertrag | Linux-Abnahme |
|---|---|---|
| Hotkeys | Aufnehmen, Toggle/Halten, Konfiguration, letzter Text | Registrierung, Druck/Loslassen, Konflikte, Neustart, Portalablehnung |
| Menü / Fenster | Tray, separate Einstellungen, Verlauf, Diagnose, Test, Import | Gleiche Einstiege und Zustände, keine eingeschränkte Sammeloberfläche |
| Overlay | Fokus bleibt erhalten; Pegel, Dauer, Pause, Kontext, Live-Rohtext | Aufnahme, Pause/Fortsetzen, Verarbeitung, Fehler, Bildschirmwechsel |
| Ausgabe | Sicheres Einfügen; Vorschau, Korrektur, Verwerfen, letzter Text | Zielprüfung, Remote-Viewer, Clipboard-Besitz; ausdrückliche Anzeige bei fehlender Plattformberechtigung |
| Verlauf | Suche, Zeitraum/Status, Details, Rohtext, Diff, Korrekturen | Bestehender Swift-Vertrag, Konflikte und abgelaufene Einträge |
| Verlauf-Aktionen | Wiederholung, erneute Bereinigung mit Vorschau, Vokabular, Löschung | Keine stillen Überschreibungen; keine dauerhafte private Vorschau |
| Allgemein | Shortcuts, Vorschau, Sounds, Overlayposition, Autostart | Gleiche Auswahlmöglichkeiten und sichere Speicherung |
| Profile | Anlegen, ändern, löschen; Vererbung, manuell/Standard | Sprache, Wörterbuch, Dienstkette, Formatierung, Datenschutz |
| App-Zuordnung | App-Regeln und eingefrorene Auftragswahl | Linux-App-Identität, keine still angewendete fremde Regel |
| Bereinigung | Aktiv / nur lokal, Provider, geordnete Kette, Keys | Vollständige Optionen, Test, Warmhaltung und Kontextgröße |
| Wörterbuch | Begriffe und Varianten; explizite Übernahme von Korrekturen | Derselbe Validator, keine automatische Lernweitergabe |
| Spracherkennung | Sprache, Modellbeschaffung, Server, Threads | Dieselben Modellgrenzen, Fortschritt und Fehler; Linux-GPU-Wahl |
| Aufnahme | Gerätewahl, Stillegrenzen, RMS/Silero | Geräteverlust, Suspend, Modellintegrität und deterministischer RMS-Rückfall |
| Aufbewahrung | Text speichern, Fristen, Diagnose-Audio, private Aufträge | Keine unfreiwillige dauerhafte Textspeicherung |
| Diagnose / Test | Dienstzustände, redigierter Bericht, isoliertes Testdiktat | Tatsächliche Desktopfähigkeiten und Phasenzeiten |
| Audiodateien | Fortschritt, Abbruch, Vorschau, unverändertes Original | Gleiche Limits und Auftragsisolation |
| Ausgewählter Text | Expliziter Auftrag, Vorschau, neue Zielprüfung | Kein Audio; geschützte Felder und Zielwechsel gesperrt |
| iPhone-Brücke | HTTPS, Token im Secret-Store, Netzgrenze, QR, begrenzte Queue | Empfangsrichtung und sämtliche Sicherheitsgrenzen unverändert |
| Sprache | DE/EN-Ressourcen und zugängliche Beschriftungen | Gleiche Bedeutungen, keine unübersetzten technischen Produktfelder |
| Paket / Updates | Vertrauensprüfung und geprüfter Installationspfad | Beide Distributionen, Datenbestand, manipulierte Pakete, Rollback |

Nachweise werden im datierten Abnahmebericht ergänzt. Plattformbedingte
Berechtigungsgrenzen werden konkret benannt und im Produkt angezeigt. Eine
fehlende Implementierung darf nicht als Plattformgrenze deklariert werden.

## Hotkey-Nachweis 2026-11-04

Die Portalverbindung registriert ihre App-ID ausdrücklich beim Host-Registry.
Der neue Status unterscheidet Freigabe, aktive Bindung und Fehler. Native
KDE-Eingabe sowie ein physischer Tastendruck erreichten die aufnahmefreie Probe.
Die lokale Tastatur sendete für die vom Benutzer betätigten Tasten tatsächlich
Strg+Meta+Leertaste; die persönliche Konfiguration wurde daran angepasst. Das ist
kein geänderter plattformweiter Standard. Mint empfing Strg+Alt+Leertaste samt
Loslassen sowohl isoliert als auch im normalen Cinnamon-Desktop. Ein aktiver
Bildschirmschoner hatte die erste Desktop-Gegenprobe verhindert.

Der vollständige X11-Ablauf einschließlich Halten und Wiederaufruf ist inzwischen
geprüft. Der Wayland-Gesamtlauf bleibt offen; die später ergänzten isolierten
Konflikt- und Neustartprüfungen sind unten gesondert beschrieben. Diese Nachweise ersetzen keine Gesamt-Abnahme.

## Silero-Nachweis 2026-11-04

Der fest gepinnte offizielle ONNX-Stand von Silero 6.2.1 verwendet wie die
CoreML-Referenz acht zustandsbehaftete 32-ms-Schritte und aggregiert mit
`1 − Produkt(1 − p)` auf 256 ms. Auf demselben gehashten künstlichen
Referenzkorpus stimmten sämtliche Entscheidungen an der Produktschwelle 0,85
überein (27 Fälle, 1089 Fenster). Die numerischen Wahrscheinlichkeiten sind
nicht identisch; die größte beobachtete Abweichung betrug 0.143103.
Das ersetzt weder weitere Qualitätsfälle noch den Mikrofon- und Segmentierungslauf
auf beiden Zielsystemen. Ein fehlendes oder beschädigtes Modell fällt explizit
auf RMS zurück; ein eigener Lauf belegt getrennte Zustände pro Aufnahmephase.

## Texteingabe-Nachweis 2026-11-04

Die native Prüfung besteht auf X11 und Wayland mit eigenen künstlichen
Zielfenstern und getrenntem Bedienungshilfen-Bus. Sie umfasst normales Einfügen,
Auswahl mit Emojis, unveränderte Formatierung außerhalb der Auswahl,
zwischenzeitliche Text-/Fokusänderungen, Passwortfelder und nachträglich
schreibgeschützte Felder. Eine während des Einfügens ausgelöste Änderung
verhindert das anschließende Löschen der ursprünglichen Auswahl; der Adapter
meldet die teilweise Übernahme ausdrücklich.

Der Qt-AT-SPI-Adapter verwendet UTF-16 für Positionen und InsertText-Längen;
die allgemeine AT-SPI-Dokumentation beschreibt für letztere UTF-8-Bytes. Die
Zielprüfung berücksichtigt den Toolkitnamen auch bei ursprünglich reinem
ASCII-Text. Der neue Adapter ersetzt nicht mehr den gesamten Feldinhalt und
erhält dadurch vorhandene Rich-Text-Formatierung außerhalb der Auswahl.

Die Linux-Kerntests bestehen unter normalen Benutzerrechten mit der echten
gepinnten Silero-Modellfixture. Die JSONL-Pipelineprüfung besteht einschließlich
Dienstwechsel, genau einer Gesamttextbereinigung und Konfliktschutz im Verlauf.
Die TLS-Prüfung verifiziert Tokenpflicht, frühzeitige Größenablehnung,
Schlüssel-/Zertifikatszuordnung und Erneuerung mit geändertem Zertifikat-Pin.
Diese Teilnachweise ersetzen weiterhin keine vollständige Produktabnahme.

## Zusammenhängende Abläufe 2026-11-04

Unter X11 besteht der native Weg vom globalen Tastendruck über die Qt-Aufnahme,
lokale Test-Transkription und genau eine Textbereinigung bis zum tatsächlichen
Einfügen in ein künstliches Feld. Toggle und Halten sind getrennt geprüft;
schnelles Loslassen vor der Aufnahme erzeugt keinen Transkriptionsauftrag.
Nach Erfolg bleiben ein Verlaufseintrag und keine WAV-Datei zurück.

Die reale Qt-Aufnahme mit künstlicher deutscher Sprache besteht mit dem lokalen
Whisper-Modell sowohl über den konfigurierten primären Textdienst als auch mit
erzwungener lokaler Bereinigung. Der letztere Nachweis verwendet eine echte
Modellausgabe statt des Rohtext-Rückfalls. Ein beim ersten Versuch verbliebener
leerer Testdienst wurde anhand seines eigenen temporären Modellverzeichnisses
entfernt; Testendpunkte starten nun keinen unnötigen Standard-Ollama-Dienst.
Ein während der Dienstprüfung beendeter Worker kann keinen verspäteten eigenen
Dienst mehr nachstarten.

Die tatsächlichen Qt-Fensteraktionen Speichern/Abbrechen und Verlaufskorrektur
mit Änderungsvergleich bestehen bei unabhängigem Lesen der gespeicherten
Dateien. Profilanlage, vererbte Bereinigung, App-Zuordnung und konsistente
Profillöschung sind ebenfalls durchgespielt. Die gemeinsamen Konfigurations-
und Diagnoseprüfungen bestehen zusätzlich unter macOS. Die vollständige
Wayland-Kette und die endgültige installierte Paketabnahme bleiben offen.

## Vorschau und Paketprobe 2026-11-04

Unbestätigte Ergebnisse bleiben bis zu einer ausdrücklichen Aktion getrennt vom
letzten bestätigten Text. Bestätigen, Verwerfen und mehrere offene Kandidaten
sind über das reale Worker-Protokoll geprüft. Die Qt-Vorschau ist wie die
Mac-Referenz schreibgeschützt und wird in Zustellreihenfolge angezeigt. Unter
X11 behielt das ursprüngliche Feld während der automatischen Vorschau den
Fokus; ein einzelner tatsächlicher Klick auf „Einfügen“ übernahm den Text.

Die vollständige interne Paketprobe besteht mit einem flüchtigen Testschlüssel:
Signaturprüfung, Installation, Start der Qt-Oberfläche und Rückkehr zur
vorherigen Installation. Sie veröffentlicht keinen Feed und ersetzt weder die
endgültige signierte Auslieferung noch deren installierte Desktop-Abnahme.

## Native Brücke und Aufruf des letzten Texts 2026-11-05

Die Brücke besteht unter Mint mit einem getrennten, temporären GNOME Secret
Service und dem im Paket enthaltenen `secret-tool`. Der Test erzeugt seine
Identität und Tokens selbst; er verwendet keinen persönlichen Schlüsselbund.
HTTPS-Zertifikat-Pin, fehlende/falsche Tokens, Erneuerung des Zugriffstokens,
Zertifikatserneuerung und Wiederladen derselben Identität nach Worker-Neustart
wurden tatsächlich geprüft.

Eine synthetische AAC-Datei wurde über die eigene `.local`-Adresse an den echten
HTTPS-Empfänger geschickt. Der Client prüfte vor dem Senden, dass die Verbindung
auf eine Adresse dieses Rechners führt und der Zertifikat-Pin stimmt. Der
Empfänger dekodierte lokal nach WAV, transkribierte über den lokalen Testdienst
und bereinigte genau einmal. Weder Token noch private Schlüssel wurden in den
Testbericht geschrieben. Ein echter iPhone-Kameratest bleibt davon getrennt.

Im nativen X11-Gesamtlauf rief der zweite globale Hotkey den zuvor bestätigten
Text wieder auf. Er wurde über die Vorschau erneut ins künstliche Feld
eingefügt, ohne erneute Aufnahme, zusätzliche Bereinigung oder neuen
Verlaufseintrag. Die separate Pipelineprüfung deckt auch Loslassen während des
Fortsetzens einer pausierten Aufnahme ab.


## Native Audioaufnahme und erneute Prüfung 2026-11-05

Die Geräteverlustprüfung zeigte, dass die zunächst verwendete Qt-Aufnahme beim
Entfernen der Quelle weiterlaufen konnte. Die Aufnahme verwendet deshalb jetzt
PulseAudio direkt, auch über die PulseAudio-Kompatibilität von PipeWire. Der
Stream verbietet eine automatische Umleitung auf ein anderes Mikrofon. Die
Geräteliste wird asynchron überwacht; ein fehlendes gespeichertes Gerät bleibt
sichtbar und wird nicht als Systemstandard ausgegeben.

Der native X11-Lauf belegt den Abbruch beim Entfernen einer künstlichen Quelle:
kein Einfügen, ein fehlgeschlagener Verlaufseintrag und erhaltene Diagnose-WAV.
Nach Wiederanlegen der Quelle gelingt ein neuer Auftrag; dessen WAV wird nach
Erfolg entfernt. Schnelles Loslassen vor dem Aufnahmebeginn sowie eine
Bildschirmschoner-Unterbrechung im Haltemodus erzeugen keinen
Transkriptionsauftrag. Ein neuer Tastendruck danach funktioniert wieder.
Vorschau und Wiederaufruf bestehen auch mit dem neuen Aufnahmeweg.

Auf beiden Zielsystemen wurde künstliche deutsche Sprache durch den neuen
Aufnahmeweg und das echte lokale Whisper-Modell verarbeitet. Sowohl der
konfigurierte primäre Textdienst als auch die erzwungene lokale Bereinigung
lieferten ein plausibles Modellergebnis ohne Rohtext-Rückfall. Diese Läufe
verwenden virtuelle Audioquellen und belegen keine physische Mikrofonhardware.
Die Fensterprüfung besteht zusätzlich für das fehlende gespeicherte Mikrofon
und den echten Dateiauswahldialog mit anschließendem Import, schreibgeschützter
Vorschau und unverändertem Original.

Die abschließende Wayland-Prüfung benötigt einen entsperrten Desktop. Eine
Sperre wird nicht durch die Testautomatisierung aufgehoben. Der reguläre Produktionsbuild besteht. Die installierte Abnahme und die
endgültige Updateauslieferung bleiben gesonderte offene Schritte; der alte Prototyp gilt dadurch nicht als
vollständig ersetzt.


## Hotkey-Grenzfälle und eigene Arbeitsfenster 2026-11-05

Der native X11-Test belegt konkurrierende Bindungen ohne Verlust des ersten
Besitzers, Caps-/Num-Lock, zwei Aktionen auf derselben Grundtaste,
Wiederholungsunterdrückung, erneutes Binden bei gehaltener Taste und Freigabe
beim Beenden. Ein eigener D-Bus-Testdienst belegt Registry-Reihenfolge,
tatsächliche statt bevorzugte Zuweisung, Abbruch/Ablehnung, ungültige
Sitzungspfade sowie erneute Registrierung nach Dienstneustart. Eine verspätete
Bindungsantwort aktiviert keine bereits geschlossene Sitzung. Dieser isolierte
Portaltest ersetzt nicht den vollständigen Lauf am echten Wayland-Desktop.

Import und Testdiktat haben eigene Fenster mit sichtbarem Profil,
Aufbewahrungsregeln und Bereinigungsweg. Die Dateiauswahl und der Dateiabwurf
starten den Import erst nach Bestätigung. Mehrere oder fremde Dateien werden
abgewiesen. Die gemeinsamen Sitzungen lehnen veraltete Konfigurationsfreigaben
vor einer Aufnahme oder Transkription ab. Der lokale Fenstertest prüft Auswahl,
Abwurf, Bestätigung, unverändertes Original und schreibgeschützte Ergebnisse.
Er prüft auch den sichtbaren Fehler bei einem fehlenden Mikrofon und die
Kopie eines Phasenberichts ohne Testtext oder private Pfade.

Testdiktat, Import und reguläre Aufnahme behalten getrennte Ergebniszuordnungen.
Ein abgeschlossener Testbericht bleibt nach einem späteren regulären Auftrag
abrufbar. Das Schließen eines inaktiven Hilfsfensters beendet keine fremde
Aufnahme. Die Auswahlbereinigung benötigt weder Audio noch einen neuen
Verlaufseintrag. Diese Fälle sind über das tatsächliche Worker-Protokoll geprüft.

Die Abschlussprüfung fand einen konkurrierenden Shutdown bei gleichzeitigem
`quit` und Pipe-Ende. Beide Auslöser verwenden jetzt denselben Vorgang auf dem
Haupt-Executor. Auch eine abgerissene Ausgabe führt durch den geordneten
Abschluss. Wiederholte Prozessläufe und die erneute Fensterprüfung bestehen.
Die beidseitige Nachrichtengrenze ist begrenzt und auch für größere
Konfigurationsnachrichten einheitlich.

Noch offen sind die Gegenprüfung der zuletzt ergänzten Hilfsfenster unter Mint,
der zusammenhängende Wayland-Desktoplauf sowie die abschließende installierte
Fassung und Updateauslieferung. Der Arbeitsstand ist weiterhin kein
freigegebenes gleichwertiges Linux-Release.

## Zusammenhängender Wayland-Lauf 2026-11-05

Der echte KDE-Desktoplauf besteht für Toggle und Halten, virtuelle Audioquelle,
lokale Transkription, genau eine Bereinigung, sicheren Zieleintrag und Verlauf.
Die zusätzlichen Durchläufe belegen fokusfreie Vorschau, ausdrückliches Kopieren,
Einfügen und Wiederaufruf ohne neue Aufnahme. AT-SPI besteht einschließlich
Unicode, geschützter Felder und zwischenzeitlich veränderter Ziele.

Automatische Wayland-Anzeigen verwenden Layer Shell mit zunächst gesperrter
Tastaturaktivierung. Erst ein ausdrücklicher Klick erlaubt die Vorschauinteraktion.
Kopieren nutzt bei verfügbarem Data Control den mitgelieferten Clipboard-Dienst.
Die Prüfung vergleicht nur künstliche Inhalte und stellt die zuvor im Speicher
gesicherte Zwischenablage anschließend wieder her. Mausnahe und unten zentrierte
Overlayposition wurden gegen die tatsächliche KDE-Arbeitsfläche geprüft.

Die Fensterprüfung auf Mint besteht in Deutsch und Englisch einschließlich
Dateiauswahl, Importbestätigung und Fehler beim fehlenden Mikrofon. Der finale
Versionswechsel und die Updateauslieferung werden anschließend separat geprüft.

## Installierte Fassung 0.9.48 — 2026-11-05

Das Produktionsarchiv ist auf beiden Zielsystemen benutzerlokal installiert.
Die installierten Binärdateien entsprechen dem geprüften Paket. Auf dem echten
Wayland-Desktop sowie in der isolierten X11-Sitzung unter Mint besteht der
zusammenhängende Durchlauf über globale Hotkeys, Aufnahme, Vorschau, Einfügen
und Wiederaufruf. Beide regulären Desktopinstanzen starten im Hintergrund und
melden die globalen Kürzel als bereit.

Die finale Paketprüfung besteht auf beiden Distributionen für Signaturprüfung,
isolierten Qt-Start, atomaren Versionswechsel und Rollback. Der reale
Modelllauf besteht auf beiden Rechnern für primäre und erzwungen lokale
Textbereinigung ohne Rohtext-Rückfall. Die Mint-Gegenprüfung bestätigt
HTTPS-Pin, lokale AAC-Dekodierung, Tokenrotation und erneuerte Identität nach
Neustart im isolierten Secret Service.

Die Linux-Widgets folgen der Gliederung und den Zuständen der Mac-App, verwenden
jedoch Qt- statt AppKit-Controls. Unter KDE benötigt die mausnahe Position eine
kurze lesende KWin-Abfrage; bei fehlender Unterstützung wird die verfügbare
Position ausdrücklich angezeigt. Fehlende Accessibility-/Clipboard-Rechte
führen zur sichtbaren manuellen Zustellung und niemals zu blindem Einfügen.

Nicht durch diese Abnahme belegt sind physische Mikrofone, ein echter
Suspend-/Resume-Zyklus, mehrtägiger Alltag und eine reale iPhone-Kopplung.
Die öffentliche Updatefreigabe bleibt bis zur lokalen Release-Signatur und
Veröffentlichungsfreigabe offen.
