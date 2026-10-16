# Verlauf durchsuchen und einzelne Diktate löschen

Das Verlaufsfenster durchsucht Rohtext und fertigen Ergebnistext gemeinsam.
Mehrere durch Leerzeichen getrennte Suchwörter müssen alle vorkommen; sie dürfen
auf Rohtext und Ergebnis verteilt sein. Großschreibung, Akzente und Umlaute
werden für die Suche gleich behandelt. Die Suche läuft ausschließlich lokal.

Mit **Zeitraum** und **Status** lässt sich die Suche weiter eingrenzen. Heute,
die letzten sieben Tage und die letzten 30 Tage bezeichnen Kalendertage in der
lokalen Zeitzone, einschließlich des heutigen Tages. Die Anzahl unten zeigt
Treffer und gesamten geladenen Verlauf. **Filter zurücksetzen** hebt bei einer
leeren Treffermenge Suche und beide Filter auf.

**⌘F** fokussiert die Suche. **Aktualisieren** beziehungsweise **⌘R** lädt den
aktuellen Dateistand erneut, etwa nach einer Änderung durch die CLI. Änderungen
aus derselben App erscheinen automatisch. Eine schnelle neue Suche ersetzt die
vorige; ein verspätetes altes Suchergebnis überschreibt sie nicht.

Nach Auswahl eines Eintrags bietet **Eintrag löschen …** eine Bestätigung an.
Die Aktion ist auch im Kontextmenü vorhanden. Abbrechen erhält den Eintrag.
Bestätigen entfernt nur diesen Text und seine eigene zurückbehaltene Aufnahme.
Andere Einträge bleiben erhalten, auch wenn App und CLI gleichzeitig schreiben.
Eine von mehreren Einträgen gemeinsam referenzierte Aufnahme bleibt für die
anderen Einträge bestehen.

Lässt sich die Aufnahme nicht löschen, verschwindet der angeforderte Text
trotzdem. Ein textfreier, sichtbarer Audioverweis bleibt für einen erneuten
Löschversuch erhalten. Dieser Löschrest lässt sich nicht erneut transkribieren;
ein bereits laufender älterer Versuch darf den gelöschten Text nicht
wiederherstellen. Unsichere Dateinamen außerhalb des Aufnahmeordners werden
abgewiesen; fremde Dateien werden nicht gelöscht.

**Alle löschen** bleibt eine eigene bestätigungspflichtige Aktion. Suche und
Filter schränken diese Aktion nicht auf die gerade sichtbaren Treffer ein.
