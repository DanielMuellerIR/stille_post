# Sicheres Einfügen

Seit 0.9.22 merkt sich Stille Post beim Aufnahmebeginn die aktive Anwendung,
ihren laufenden Prozess, das fokussierte Fenster und das Textfeld. Vor dem
Einfügen müssen diese Identitäten wieder übereinstimmen. Die Prüfung liest
keinen Inhalt fremder Textfelder. Abfragen an eine langsame Ziel-App sind
zeitlich begrenzt.

Ist ein anderes Ziel fokussiert, wurde die App beendet oder liefert macOS keine
eindeutige Zuordnung, bleibt das vollständige Ergebnis in der Zwischenablage.
Ein blauer Hinweis erklärt den Grund und fordert zum manuellen Einfügen mit
⌘V auf. Stille Post aktiviert keine frühere App und kein früheres Fenster.
Bildschirmfreigabe bleibt ebenfalls ein Fall für manuelles Einfügen.

Nach automatischem Einfügen wird die frühere Zwischenablage einschließlich ihrer
Datentypen wiederhergestellt. Hat der Nutzer inzwischen etwas Neues kopiert,
bleibt dieser neuere Inhalt erhalten. Ändert sich die Zwischenablage bereits während der Zielprüfung, wird nichts
automatisch eingefügt. Der neuere Inhalt bleibt erhalten. Ein roter Hinweis
erklärt, dass sich das Diktat über den letzten Text erneut abrufen lässt; er
verspricht keinen Diktattext in der Zwischenablage. In den übrigen manuellen
Fällen bleibt der Diktattext bereit; eine automatische Wiederherstellung findet
dann nicht statt.

## Grenzen

Die Prüfung gilt für App, Fenster und Textfeld. Sie speichert keine Cursorposition
oder Auswahl innerhalb des Felds. Ein verschobener Cursor im gleichen Textfeld
bleibt daher das aktuelle Einfügeziel. Manche Apps stellen über die
Bedienungshilfen keine stabilen oder unterstützten Textfeldidentitäten bereit;
in diesem Fall wird ausschließlich kopiert.

macOS bietet keine atomare Operation aus Fokusprüfung und synthetischem ⌘V.
Ein Fokuswechsel genau während der Eventzustellung lässt sich deshalb nicht
vollständig ausschließen. Nach den Metadaten-Abfragen werden Fenster- und Feldfokus erneut mit dem
ursprünglichen Ziel verglichen. App, Berechtigung und eigener
Clipboard-Änderungszähler werden unmittelbar vor dem Senden ebenfalls geprüft.
Alle AX-Abfragen teilen ein Zeitbudget von 250 ms; eine fehlende Zuordnung oder
ein ausgeschöpftes Budget erlaubt kein automatisches Einfügen.

## Prüfung am 2026-10-16

Die Kernentscheidung und die bestehenden Zwischenablage-Verträge bestanden die
Swift-Tests. Eine native Gegenprobe führte den unveränderten produktiven
PasteService an echten AppKit-Fenstern und Textfeldern aus:

- Im gleichen Ziel kam der Text durch das synthetische ⌘V an; die frühere
  Zwischenablage wurde danach wiederhergestellt.
- Bei App-, Fenster- und Feldwechsel sowie geschlossenem Fenster oder beendeter
  App wurde ausschließlich kopiert. Auch unbekannte Ziele und ein Fenster ohne
  Textfeld erhielten kein automatisches Einfügen.
- Die echte macOS-Bildschirmfreigabe als Vordergrund-App führte zu manuellem
  Einfügen und behielt den Text in der Zwischenablage.
- Eine separate App-Probe ohne Bedienungshilfen-Recht lieferte den bestehenden
  Berechtigungshinweis-Fall und behielt den Text in der Zwischenablage.
- Eine neue Kopieraktion nach automatischem Einfügen wurde nicht überschrieben.

Die beiden neuen Hinweise wurden in DE/EN am installierten, notarisierten Bundle
0.9.22 einschließlich automatischem Ausblenden geprüft. Die native Gegenprobe
verwendete künstliche Textfelder; sie ersetzt keine mehrtägige Abnahme sämtlicher
Zielprogramme oder einen vollständigen Live-Diktierlauf mit physischem Mikrofon.
Die offenen Gerätefälle stehen weiterhin im [Backlog](../backlog.md).
