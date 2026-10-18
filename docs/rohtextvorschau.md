# Laufende Rohtextvorschau

In **Einstellungen → Allgemein → Ergebnis** lässt sich **Laufenden Rohtext anzeigen** einschalten. Die Option gilt ab dem nächsten Diktat und bleibt während eines Auftrags eingefroren. Alte Konfigurationen lassen sie ausgeschaltet.

Das Aufnahmeoverlay zeigt abgeschlossene Segmente in ihrer Aufnahme-Reihenfolge. Eine spätere Antwort wartet auf frühere Segmente. Fehlt ein Segment, endet die Vorschau vor dieser Lücke und kennzeichnet sie. Bei langem Sprechen ohne Pause erscheint Text erst mit dem nächsten Segmentabschluss; dies ist keine Wort-für-Wort-Vorschau.

Der Bereich zeigt einen begrenzten Ausschnitt des Rohtexts: höchstens 600 Zeichen und fünf sichtbare Zeilen, bei einer Fehlerwarnung drei. Frühere Wörter können aus der Anzeige fallen; der vollständige Rohtext bleibt für die Endverarbeitung erhalten. Die Anzeige ist vorläufig, noch nicht bereinigt und übernimmt weder Tastaturfokus noch Zwischenablage. Die Buttons zum Pausieren/Fortsetzen und Beenden bleiben bedienbar.

In einer Pause und während der Fortsetzung bleibt der aktuelle Text stehen. Stoppen, Abbrechen, Fehler oder neuer Start entfernen ihn. Profil-, Sprach-, Wörterbuch-, Bereinigungs- oder Aufbewahrungsänderungen blenden die Vorschau bis zum nächsten Start aus. Der laufende Auftrag verwendet weiterhin seine ursprüngliche Konfiguration. Das Testdiktat und die Brücke öffnen kein globales Aufnahmeoverlay.

Die Vorschau nutzt nur ohnehin abgeschlossene lokale Transkriptionsanfragen. Sie erzeugt keine weiteren Requests, Verlaufseinträge oder Logs. Erst der vollständige Text erhält wie bisher genau einen logischen Bereinigungsauftrag; Audio bleibt lokal.
