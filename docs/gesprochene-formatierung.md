# Gesprochene Formatierung

Unter **Einstellungen → Bereinigung → Gesprochene Formatierung** lässt sich die
standardmäßig ausgeschaltete Funktion aktivieren. Unter **Profile → Formatierung**
kann jedes Profil den globalen Wert erben oder ausdrücklich ein-/ausschalten.
Die Option ist unabhängig vom eigenen Bereinigungsbereich und funktioniert auch
bei ausgeschalteter LLM-Bereinigung vollständig lokal.

| Ausdrücklicher Befehl | Ausgabe |
| --- | --- |
| `Format neuer Absatz` / `format new paragraph` | Absatz mit Leerzeile |
| `Format neue Zeile` / `format new line` | Zeilenumbruch |
| `Format Liste Anfang` / `format list start` | Erste Listenzeile mit `• ` |
| `Format Listenpunkt` / `format bullet point` | Nächste Listenzeile mit `• ` |
| `Format Liste Ende` / `format list end` | Liste beenden, Umbruch zum Fließtext |
| `Format Anführungszeichen Anfang` / `format quote start` | Wörtliches Zitat beginnen |
| `Format Anführungszeichen Ende` / `format quote end` | Zitat schließen |

Groß-/Kleinschreibung und von der Spracherkennung zwischen den Befehlswörtern
gesetzte Satzzeichen sind zulässig. „Neuer Absatz“ allein bleibt normaler Text.
Andere Wörter wie „Liste“, „Listenpunkt“ oder „quote“ lösen keine Aktion aus.
Vollständige Befehlsformen als Beispiele müssen zitiert oder in einem wörtlichen
Block stehen. Es gibt keine allgemeinen Sprach-, System- oder Shell-Aktionen.
Ausdrückliche Umbrüche am Textanfang und -ende bleiben erhalten. Ein Auftrag nur
aus Formatierungsbefehlen wird als normaler Text behandelt; er löst keine leere
Ausgabe oder eigenständige Systemaktion aus.

Ein Listenanfang erzeugt den ersten Punkt; vorangehender Fließtext wird mit einem
Umbruch getrennt. Jeder weitere Punkt benötigt den Listenpunktbefehl. Nach dem
Listenende folgt Fließtext auf einer neuen Zeile. Fehlt das Ende, läuft die Liste
bis Textende. Absatz-/Zeilenbefehle innerhalb eines Eintrags bleiben wirksam und
beenden die Liste nicht. Es gibt eine Listenebene: Bei verschachtelten Listen oder
leeren Einträgen bleibt der gesamte betreffende Block samt Befehlen wörtlich.
Listenpunkt und Listenende ohne Anfang bleiben ebenfalls wörtlich. Mehrere Listen
nacheinander sind möglich; ausdrücklich gesprochene zusätzliche Umbrüche bleiben.

Ein geschlossener gesprochener Quote erzeugt `„…“` bei deutschem Anfang und `“…”`
bei englischem Anfang; Anfang/Ende dürfen beide Sprachen mischen. Der innere Text
bleibt exakt erhalten, einschließlich Unicode, Zeilenumbrüchen und darin genannten
Formatbefehlen. Nur der Trennleerraum unmittelbar an den Befehlen entfällt.
Offene oder verschachtelte gesprochene Quotes bleiben im betroffenen Bereich samt
Befehlen wörtlich; ein fehlendes Ende wird nie automatisch ergänzt. Ein verwaister
Endbefehl bleibt Text. Der zuerst beginnende Literal-/Quote-Bereich schützt seinen
Inhalt; darin gesprochene andere Befehle öffnen keine weitere Aktion. Ein weiterer
gesprochener Quote-Anfang macht den Quote ausdrücklich ungültig.

Beispiel: `Format Liste Anfang 128, nicht 256. Format Listenpunkt Format
Anführungszeichen Anfang Version 1.2 Format Anführungszeichen Ende Format Liste
Ende Danach.` ergibt:

```text
• 128, nicht 256.
• „Version 1.2“
Danach.
```

Passagen in geraden oder typografischen Anführungszeichen bleiben wörtlich;
englische Apostrophe innerhalb eines Wortes öffnen kein Zitat. Ein ungeschlossenes
Zitat schützt vorsichtshalber den Rest. Für gesprochene Beispiele eignen sich
**Format wörtlich Anfang … Format wörtlich Ende** beziehungsweise
**format literal start … format literal end**. Die begrenzenden Befehle entfallen,
der Inhalt bleibt einschließlich darin genannter Formatierungsbefehle erhalten.
Fehlt das Ende, bleibt auch der Anfangsbefehl normaler Text und der Rest geschützt.

Die Absicht wird ausschließlich im vollständigen ursprünglichen Rohtext erkannt.
Eine Modellantwort kann keine neuen Befehle auslösen. Genau ein Bereinigungsauftrag
verarbeitet den geordneten Gesamttext; zufällige Markierungen tragen nur bereits
erkannte Positionen durch das Modell. Identität, Anzahl, Reihenfolge und Position relativ zu Inhaltswörtern und
Unicode-Symbolen zwischen den Markierungen werden streng geprüft. Eindeutige
Sprechpausen und unmittelbare Wortwiederholungen dürfen innerhalb desselben
Bereichs entfernt werden; Wortersetzungen sind für den Positionsbeleg zu unsicher. Wörtliche Passagen werden anschließend aus dem Rohtext
wiederhergestellt. Ein zusätzlicher Vergleich ohne Markierungen erhält die
bestehenden Regeln für Worttreue, Zahlen, Negationen und bestätigte Varianten.
Varianten gelten ausschließlich außerhalb geschützter Passagen.

Verliert, verändert oder verschiebt das Modell Markierungen, bleibt lokal formatierter
Rohtext verfügbar. Die Anzeige nennt den Rohtext-Rückfall. Bei ausgeschalteter
LLM-Bereinigung lautet die Herkunft **Lokal formatiert**; es entsteht keine
Text-Netzwerkanfrage. Ohne erkannte Aktion bleibt die Herkunft **Rohtext**.
Bei erfolgreicher Modellverarbeitung lautet sie **Bereinigt**.

Aufnahme, Testdiktat, Dateiimport, CLI und Brücke behalten die beim Start
festgehaltene Einstellung. Ein Profilwechsel wirkt erst auf folgende Aufträge.
CLI `transcribe --raw` und Brücke `/v1/dictate?raw=1` liefern ausdrücklich Rohtext
und überspringen auch die Formatierung. Brückenantworten enthalten zusätzlich die
Herkunft `origin` (`raw`, `formatting`, `cleanup` oder `rawFallback`).

Rohtext, ursprüngliche Ausgabe und bis zu drei Vorfassungen bleiben im Verlauf
unverändert erhalten. **Erneut bereinigen** erstellt auch bei rein lokaler
Formatierung zunächst eine Vorschau. Erst **Übernehmen** speichert die neue
Fassung; automatisches Einfügen findet dabei nicht statt. Alte Konfigurationen
lassen die Funktion aus; alte Profile erben den globalen Wert und behalten ihre IDs.

Die ausdrückliche Auswahlbereinigung über Menü und macOS-Dienst nutzt denselben
Cleaner und dieselbe beim Start festgehaltene Option. Auswahl und Vorschau bleiben
im RAM, ohne Verlaufseintrag oder Änderung des letzten Diktats. Ein Dienst ohne
nachweisbaren Ursprung bleibt ausschließlich lokal und bietet kein Ersetzen an.
Ersetzen verlangt weiterhin das unveränderte konkrete Ziel und eine ausdrückliche
Übernahme; fremde Aktivierung sperrt es auch nach Rückkehr.
