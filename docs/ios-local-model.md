# Lokales Modell auf dem iPhone

Stand: 2026-10-18. Version 0.9.43 ergänzt die Modellverwaltung.
Entwicklungskandidat 0.9.44 verbindet diese Verwaltung mit dem getrennt
beschriebenen [Offline-Diktatablauf](ios-offline-dictation.md). Dessen menschliche
Geräteabnahme ist noch offen.

## Bedienung

„Lokales Modell verwalten“ öffnet die Modellansicht. Herunterladen, Fortsetzen,
Laden und Freigeben werden ausschließlich durch die jeweilige Schaltfläche
gestartet. Ein Neustart der App lädt oder setzt nichts automatisch fort.

Der Download benötigt WLAN. Das feste Modell einschließlich Tokenizer umfasst
648.663.349 Byte; zusätzlich müssen 2 GiB Speicher für die gerätespezifische
CoreML-Aufbereitung frei bleiben. Diese Reserve ist eine vorsichtige
Kapazitätsgrenze, keine Messung des gesamten CoreML-Cachebedarfs. Die erste
Aufbereitung kann mehrere Minuten dauern. Während Download, Integritätsprüfung
und Laden bleibt das Display höchstens zehn Minuten wach; manuelle Sperre und
Hintergrundwechsel bleiben wirksam.

„Download pausieren“ behält bereits vorhandene Teile. Nach einem App-Neustart
setzt „Download fortsetzen“ die fehlenden Bytes ausdrücklich fort. Ein Server,
der Range-Anfragen ignoriert, beginnt die betreffende Datei neu; alte Bytes
werden dabei ersetzt. Erst nach vollständiger Größen- und SHA-256-Prüfung
werden alle Dateien gemeinsam als vorhanden freigegeben. Vor jedem Laden
werden sämtliche Hashes erneut geprüft.

„Modell aus dem Speicher freigeben“ entfernt die geladenen Modellreferenzen.
Hintergrundwechsel, Speicherdruck und Schließen der Modellansicht fordern
ebenfalls Abbruch und Freigabe an. Ein bereits laufender nativer CoreML-Aufruf
kann erst nach seiner Rückkehr freigegeben werden. Bis dahin bleibt ein neuer
Start gesperrt. Die Rückkehr in den Vordergrund lädt nichts automatisch.

„Modelldateien entfernen“ verlangt eine Bestätigung und löscht ausschließlich
die eigene Modellablage und angefangene Downloads. Aufnahmen und Kopplung
bleiben erhalten. Zusätzliche CoreML-Systemcaches verwaltet iOS. Die
heruntergeladenen Dateien sind von Gerätebackups ausgeschlossen.

## Feste Quellen und Datenschutz

- [Argmax OSS / WhisperKit 1.1.1](https://github.com/argmaxinc/argmax-oss-swift/tree/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4),
  ausschließlich das WhisperKit-Produkt.
- [Whisper large-v3-turbo für CoreML](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-large-v3-v20240930_turbo_632MB),
  Revision `0f63a7800b00dd0226abd051b906c246e1907482`.
- [OpenAI-Tokenizer](https://huggingface.co/openai/whisper-large-v3-turbo/tree/41f01f3fe87f28c78e2fbf8b568835947dd65ed9),
  Revision `41f01f3fe87f28c78e2fbf8b568835947dd65ed9`.

Der mitgelieferte Katalog enthält für jede Datei Größe, SHA-256 und eine URL mit
fester Revision. Der Gesamtempfang ist begrenzt; unerwartete Antwortgrößen,
Range-Angaben und beschädigte Dateien werden abgewiesen. Modell-GETs verwenden
HTTPS ohne Cookies, Zugangsdaten, Proxys oder Antwortcache. Nur die öffentlichen
Modell-GETs erlauben die erforderlichen Hugging-Face-CDN-Weiterleitungen.
Die Redirectsperre der Mac-Brücke bleibt erhalten.

Der lokale Adapter verwendet ausschließlich die vorher geprüften Dateien und
den lokalen Tokenizer. Der automatische Tokenizer-Hub-Rückfall des SDK wird
dadurch vermieden. Es gibt keine Ersatzengine oder automatische Cloud-Erkennung.
Der Modell-Downloader nimmt weder Audio noch Diktattext entgegen. SDK und
Whisper stehen unter MIT; die vollständigen Hinweise sind in der Modellansicht
über „Modell und Lizenzen“ erreichbar.

## Modellentscheidung und Prüfgrenzen

Die komprimierte large-v3-turbo-Variante ist wegen ihrer begrenzten Ressourcen
und der erfolgreich ausgeführten Geräteproben ausgewählt. Die größere Variante
korrigiert zwar zusätzliche deutsche Wortverwechslungen, darunter einen
Formatbefehl. Auf dem iPhone blieb sie jedoch über die vorab gesetzte Grenze
von sechs Minuten hinaus in der ersten CoreML-Aufbereitung und wurde beendet.
Für sie liegt deshalb kein abgeschlossener Speicher- oder Erkennungsbefund vor.
Eine erfolgreiche spätere Aufbereitung oder gecachte Starts dieser Variante
wurden nicht geprüft. Für den festgelegten Ladevertrag wird deshalb die
komprimierte Variante verwendet. Der direkte
CoreML-Vergleich verwendet dieselben künstlichen DE/EN-Dateien mit festen
30-Sekunden-Fenstern, festen Sprachen, einem Worker, normalen Zeitstempeln und
den fünf Temperatur-Fallbacks des SDK-Standardprofils:

| Variante | DE-Wortfehler / Referenzwörter | EN-Wortfehler / Referenzwörter |
|---|---:|---:|
| Komprimiert, 648.663.349 Byte | 41 / 264 | 56 / 277 |
| Unkomprimiert, 1.641.458.882 Byte | 39 / 264 | 53 / 277 |

Diese Zahlen enthalten auch Unterschiede zwischen geschriebenen Zahlen und
Ziffern. Eigennamen, Zahlen und Formatbefehle bleiben anspruchsvolle Fälle.
Das andere Segmentraster erlaubt keine unmittelbare Gleichsetzung mit dem
[älteren 15-Sekunden-Mac-Vergleich](asr-vad-vergleich.md). Stille und Klicks
können ohne VAD weiterhin erfundene Wörter erzeugen. Der spätere Offline-Ablauf
benötigt daher eine passende Leer-/Sprachaktivitätsprüfung und eigene menschliche
Mikrofonabnahmen.

Am iPhone 16 Pro Max mit iOS 26.6.2 bestand der endgültige komprimierte
Kandidat den vollständigen künstlichen Korpus mit 30-Sekunden-Fenstern: DE
41/264 und EN 56/277 Wortfehler. Die erste Aufbereitung dauerte 176,5 Sekunden.
Der beobachtete Prozesspeak dieses Durchlaufs betrug 207.537.624 Byte,
nach Freigabe waren es 38.585.552 Byte. Frühere längere Durchläufe mit
15-Sekunden-Fenstern erreichten 879.232.832 Byte. Diese alle 25 ms beobachteten
`phys_footprint`-Werte erfassen ANE-/Systemcaches nicht vollständig und sind
keine Garantie für den gesamten Speicherbedarf. Der thermische Zustand blieb
bei der abschließenden Probe normal.

Die Produktansicht wurde zusätzlich am iPhone manuell abgenommen: ausdrückliches
Laden, Freigeben nach Hintergrundwechsel, erneutes Laden und ausdrückliches
Freigeben sowie App-Neustart ohne automatisches Laden. Eine absichtlich beschädigte
Modelldatei wurde vor dem Laden abgewiesen. Bestätigtes Entfernen führte zu
„Modell fehlt“; auch ein später neu begonnener Download-Teilstand ließ sich
entfernen. Das abschließende Dateiinventar bestätigte eine leere Modellablage.
Drei XCTest-Starts scheiterten bereits beim Aktivieren der UI-Automation; kein
Geräte-XCTest-Fall wurde ausgeführt. Die manuelle Abnahme ist davon getrennt.

Die Mac-Verbindung war vor dieser Abnahme bereits ungekoppelt und blieb so.
Der Erhalt einer eingerichteten Kopplung während der Modellaktionen wurde am
Gerät daher noch nicht geprüft. Im Aufnahmeordner vorgefundene neue Dateien
wurden nicht verändert oder entfernt; ihr Inhalt wurde nicht gelesen.

Simulatorprüfungen auf iOS 17.5 belegen Download und Oberfläche, keine
Leistungsfreigabe für ältere Hardware. Die Produktuntergrenze bleibt iOS 17;
ein physisches Gerät mit iOS 17 und menschliche Mikrofonaufnahmen sind noch
nicht geprüft. Der Mac-Weg bleibt ausdrücklich auswählbar.
