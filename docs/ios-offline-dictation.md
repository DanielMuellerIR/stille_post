# Offline-Diktat auf dem iPhone

Stand: 2026-10-19. Entwicklungskandidat 0.9.44. Die menschliche Geräteabnahme
des vollständigen Offline-Ablaufs steht noch aus.

## Benutzung

1. „Lokales Modell verwalten“ öffnen und das feste Modell herunterladen. Dafür
   wird WLAN benötigt; [Größe, Speicherreserve und Quellen](ios-local-model.md)
   bleiben unverändert.
2. In der Diktatansicht „Auf diesem iPhone“ und „Deutsch“ oder „English“ wählen.
   Die Auswahl bleibt nach einem App-Neustart erhalten. „Diktat öffnen“ über
   Kurzbefehl oder Aktionstaste öffnet dieselbe Auswahl und startet keine Aufnahme.
3. „Aufnehmen“ und nach dem Sprechen „Aufnahme stoppen“ antippen. Die Grenze
   bleibt drei Minuten beziehungsweise 5 MB. Eine vorhandene Aufnahme wird
   nicht überschrieben. Nach dem Stoppen ist ein ausdrücklicher Wechsel des
   Verarbeitungswegs möglich; die Auswahl allein überträgt nichts.
4. „Auf diesem iPhone erkennen“ starten. Das Modell wird geprüft und bei Bedarf
   geladen; seine erste Aufbereitung kann mehrere Minuten dauern. Die Anzeige
   unterscheidet Laden und Erkennung. Nach Abschluss wird es wieder freigegeben.
5. Den als lokal beschrifteten Text ausdrücklich kopieren und in der gewünschten
   App einsetzen. Die Zwischenablage bleibt auf diesem Gerät und läuft nach
   zwei Minuten ab. Das Ergebnis liegt im Arbeitsspeicher; es ist kein Textverlauf.

„Auf meinem Mac“ behält den bestehenden [verschlüsselten Brückenablauf](ios-bridge.md).
Es gibt keinen automatischen Wechsel zu diesem Weg, wenn lokale Erkennung
scheitert oder später wieder ein Netzwerk verfügbar wird.

## Unterbrechungen und Aufnahmen

Während Aufnahme oder Verarbeitung bleibt die Auswahl gesperrt. Abbruch der
Erkennung, Hintergrundwechsel und Speicherdruck erhalten die Aufnahme zum
ausdrücklichen Wiederholen oder Verwerfen. Bei ernstem thermischem Zustand wird
angehalten; ein neues lokales Diktat wartet auf ein abgekühltes Gerät. Bereits
begonnene native Modellarbeit muss zuerst zurückkehren, bevor Freigabe und ein
neuer Start möglich sind. Der Zustand „wird beendet“ kennzeichnet diese Zeit.
Es gibt keine automatische Fortsetzung.

Erfolgreiche Erkennung entfernt ausschließlich die eigene temporäre Aufnahme
und ihre Metadaten. Bei Fehler oder leerem Ergebnis bleiben sie erhalten.
App-Neustart zeigt eine vorhandene Aufnahme, ohne sie zu verarbeiten. Der
ausdrückliche Aufnahmeabbruch oder bestätigtes Verwerfen entfernt sie. Kopplung
und Modellablage werden durch diese Aufnahmeaktionen nicht gelöscht.

## Textqualität und Datenschutz

Die Erkennung verwendet den festen komprimierten Whisper-large-v3-turbo-Kandidaten
mit lokalen Tokenizerdateien. PCM bleibt im Arbeitsspeicher und wird begrenzt in
geordnete Fenster bis 30 Sekunden aufgeteilt. Die Signalvorauswahl unterdrückt
Stille, einzelne Klicks und stationäres Rauschen. Randstille wird erhalten, weil
ihr Beschnitt kurze Nein/No-Antworten im echten Modell verlor. Die Vorauswahl
ist kein Sprachklassifikator; andere Geräusche oder zu leise Sprache können
weiterhin falsche beziehungsweise leere Ergebnisse verursachen.

Die Teile werden in Reihenfolge zusammengefügt. Ein fehlender abschließender
Punkt wird ergänzt; es gibt keine lokale LLM-Bereinigung und keine Ersetzung
gesprochener Formatbefehle. Namen, Fachbegriffe, Zahlen und Verneinungen brauchen
weiterhin Kontrolle. Der lokale Text wird entsprechend beschriftet.

Aufnahme und Erkennung benötigen nach dem Modelldownload keine Verbindung.
Es gibt keinen Audio- oder Cloud-Rückfall. Erst „Nur Text am Mac bereinigen“
sendet den vollständigen Text über die bestehende HTTPS-/Pin-/Token-Verbindung;
dieser Aufruf enthält keine Audiodatei. Die Bereinigungseinstellungen des Macs
gelten, einschließlich dort eingerichteter externer Textdienste. Das lokale
Original bleibt im Ergebnis aufklappbar. Ein Fehler oder Abbruch erhält den
vorherigen Text. Erneute Bereinigung ist ebenfalls ausdrücklich auszulösen.

## Prüfstand und Grenzen

Kernprüfungen decken Begrenzung, Reihenfolge, fehlendes Modell, Abbruch mit
verspätetem nativen Ende, Aufnahmeerhalt, Neustart sowie den ausschließlich
textlichen Aufruf über realen gepinnten TLS-Transport ab. Die native Ansicht
ist im Simulator in DE/EN und mit größter Bedienungshilfenschrift geprüft.
Eine künstliche Kopplung und zuvor vorhandene Aufnahme überstanden dort
Modell-Entfernen und App-Neustart. Ein künstliches Diktat mit echtem Modell
lieferte unter iOS 26.5 kopierbaren Text und gab das Modell wieder frei.

Der vollständige künstliche AAC-Ablauf mit gesperrtem macOS-Netzzugriff ergab
41 Wortabweichungen bei 264 deutschen und 57 bei 277 englischen Referenzwörtern.
Geschriebene Zahlen gegenüber Ziffern zählen dabei mit. Kurze Nein/No-Antworten,
Verneinungs- und leise Sprachproben wurden erkannt; Stille, stationäres Rauschen
und Klicks führten zum Fehler ohne Text und mit erhaltener Aufnahme. Dies ist
keine menschliche Mikrofon- oder physische iPhone-Netzabnahme.

Die CoreML-Aufbereitung eines iOS-17.5-Simulatorlaufs endete mit einem
Heap-Abbruch in BNNS/Espresso. Daraus folgt noch keine Aussage über ein
physisches iOS-17-Gerät; dessen Offline-Kompatibilität bleibt zu prüfen.
Die App-Untergrenze bleibt iOS 17. Simulatorprüfungen sind keine Leistungs-
oder Mikrofonabnahme älterer Hardware. Menschliche Flugmodus-, DE/EN-, Langtext-
und Unterbrechungsabnahmen auf dem iPhone bleiben bis zur Durchführung offen.

## Zusammenführung am 2026-11-06

Der bisher lokale Kandidat wurde mit dem privaten Entwicklungsstand 0.9.48
zusammengeführt. Alle 50 `StillePostClientCore`-Prüfungen bestanden in der
bestehenden macOS-Benutzersitzung; `xcodebuild build-for-testing` für den
generischen iOS-Simulator bestand ohne Signierung. Der SSH-Lauf konnte zuvor
sechs Zertifikatsfixtures wegen des dort gesperrten Schlüsselbunds nicht anlegen.
Die oben genannten menschlichen iPhone-Abnahmen bleiben offen.
