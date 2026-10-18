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

Groß-/Kleinschreibung und von der Spracherkennung zwischen den Befehlswörtern
gesetzte Satzzeichen sind zulässig. „Neuer Absatz“ allein bleibt normaler Text.
Andere Befehle, Listen und Anführungszeichen sind noch nicht implementiert.
Ausdrückliche Umbrüche am Textanfang und -ende bleiben erhalten. Ein Auftrag nur
aus Formatierungsbefehlen wird als normaler Text behandelt; er löst keine leere
Ausgabe oder eigenständige Systemaktion aus.

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
erkannte Positionen durch das Modell. Identität, Anzahl und Reihenfolge werden
streng geprüft. Wörtliche Passagen werden anschließend aus dem Rohtext
wiederhergestellt. Ein zusätzlicher Vergleich ohne Markierungen erhält die
bestehenden Regeln für Worttreue, Zahlen, Negationen und bestätigte Varianten.
Varianten gelten ausschließlich außerhalb geschützter Passagen.

Verliert oder verändert das Modell Markierungen, bleibt lokal formatierter
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
