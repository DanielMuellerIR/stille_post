# Textaufbewahrung und Diktat ohne Textverlauf

Unter **Einstellungen → Verlauf** lässt sich Text neuer Diktate unbegrenzt,
für einen, sieben oder 30 Tage aufbewahren oder ganz vom dauerhaften Verlauf
ausschließen. Die Vorgabe bleibt unbegrenzte Textaufbewahrung. Eine neue Regel
verändert vorhandene Einträge nicht nachträglich. Die Frist wird bei Erstellung
des Eintrags anhand von Kalendertagen festgelegt und als Zeitpunkt gespeichert.

Der Menüschalter **Neue Diktate ohne Textverlauf** schaltet das Textspeichern
vorübergehend aus, bis er ausgeschaltet oder die App beendet wird. Eine bereits
laufende Aufnahme behält ihre Startregel. Dauerhaft ausgeschaltetes Textspeichern
in den Einstellungen hat Vorrang; der Menüschalter ist dann ausgewählt und gesperrt.

Ohne Textverlauf enthält bereits der erste dauerhafte Zwischenstand weder Rohtext
noch Ergebnis oder freie Fehler-/Bereinigungsdiagnosen. Nach erfolgreicher
Verarbeitung und Audiolöschung bleibt kein privater Verlaufseintrag zurück.
Scheitert die Verarbeitung oder Audiolöschung, bleibt ein sichtbarer textfreier
Verweis auf die lokale Aufnahme erhalten. Die Aufnahme kann bewusst erneut
verarbeitet oder über die bestätigte Einzellöschung entfernt werden.

**Erneut transkribieren** startet eine neue Verarbeitung. Dabei gilt die strengere
der ursprünglichen und der aktuell gewählten Textregeln; eine Frist wird nicht
verlängert. Eine erstmals gewählte Textfrist beginnt mit dem neuen Verarbeitungslauf;
die vorhandene Aufnahme behält ihre bisherige Audiofrist. Bereits textfreie oder abgelaufene Einträge speichern auch nach einer
Wiederholung keinen Text. Ihr fertiges Ergebnis erscheint in der flüchtigen
Vorschau und lässt sich dort kopieren, einfügen oder verwerfen. Eine ausdrückliche
Löschung kann durch eine verspätete Wiederholung nicht rückgängig gemacht werden.

Fehleraufnahmen haben eine **eigene** Regel: bis zur manuellen Löschung (Vorgabe)
oder ausdrücklich sieben beziehungsweise 30 Tage. Auch diese Frist gilt nur für
neue Aufnahmen. Eine Textfrist löscht niemals Audio. Eine Audiofrist entfernt nur
die Aufnahme; Text bleibt entsprechend seiner eigenen Regel erhalten. Eine von
anderen Einträgen benötigte gemeinsame Aufnahme wird nicht mit gelöscht.
Abgelaufene Aufnahmen lassen sich nicht erneut transkribieren.

Fristen werden beim Start und während des App-Betriebs geprüft. Bei geschlossener
App läuft kein Löschdienst; der nächste Start holt fällige Arbeit nach. Das Lesen
des Verlaufs, auch durch die CLI, wendet fällige Textfristen an. Schreib- oder
Löschfehler werden gemeldet und erhalten nötige Dateiverweise für einen späteren
Versuch. Ein fehlgeschlagener Löschversuch wird nicht als erfolgreich ausgegeben.

Ohne Textverlauf bedeutet nicht ohne jeden flüchtigen Text: Das aktuelle Ergebnis
und **Letzter Text** können bis zum Beenden im RAM bleiben. Die Zwischenablage ist
ein eigener Speicher. Die optional konfigurierte Bereinigung kann weiterhin
Text an ihre Dienste senden. Audio bleibt entsprechend der bestehenden lokalen
Verarbeitung geschützt. Die Netzwerk-Brücke und CLI-Transkription schreiben
weiterhin keinen Diktatverlauf; diese Funktion führt dort keine Speicherung ein.
