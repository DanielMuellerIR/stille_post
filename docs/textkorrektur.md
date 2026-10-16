# Ergebnistext korrigieren und vergleichen

**Verlauf → Bearbeiten** öffnet den Editor für einen erfolgreichen Eintrag.
Unter **Text** lässt sich das Ergebnis ändern. **Speichern** übernimmt die
Korrektur; **Abbrechen** verwirft den ungespeicherten Entwurf. **Entwurf kopieren**
kopiert ausdrücklich den angezeigten Text. Die Kopieraktion in der Verlaufszeile
verwendet immer die aktuell gespeicherte Ergebnisfassung.

Der Whisper-Rohtext bleibt unverändert. Die erste manuelle Speicherung erhält
zusätzlich die ursprüngliche Ausgabe, einschließlich ihrer Herkunft als
Bereinigung oder Rohtext-Rückfall. Der aktuelle Ergebnistext wird als manuell
korrigiert gekennzeichnet. Unter **Fassungen** lassen sich Rohtext, ursprüngliche
Ausgabe und höchstens drei vorherige Ergebnisfassungen lesen und kopieren.
Ältere Vorfassungen entfallen beim nächsten Speichern. Ein unveränderter Entwurf
erzeugt keine zusätzliche Fassung.

**Vergleich** zeigt den unveränderlichen Rohtext und den aktuellen Entwurf.
Entfernte Teile sind durchgestrichen, hinzugefügte Teile unterstrichen. Wörter,
Zahlen, Satzzeichen und Leerraum bleiben beim Vergleich erhalten. Die Berechnung
läuft außerhalb des Hauptthreads; ein neuer Entwurf ersetzt einen laufenden
Vergleich. Gemeinsamer Anfang und Schluss werden vor dem Wortvergleich abgezogen.

Der Vergleich begrenzt seine Matrix auf zwei Millionen Zellen und die
Tokenisierung auf 40.000 Token, 250.000 Zeichen beziehungsweise zwei Millionen
UTF-8-Bytes. Bei größeren Unterschieden zeigt er ausdrücklich die vollständige
alte und neue Fassung statt einzelner Wortmarkierungen. Diese Grenze verändert
keinen gespeicherten Text.

Alle Fassungen unterliegen derselben [Textaufbewahrung](aufbewahrung.md).
Private, gelöschte, abgelaufene und fehlgeschlagene Einträge lassen sich nicht
korrigieren. Wird ein geöffneter Text gelöscht oder läuft er ab, entfernt der
Editor seine Textkopien. Die Zeitprüfung im geöffneten Editor erfolgt jede Sekunde;
Speichern und Kopieren prüfen die Verfügbarkeit zusätzlich unmittelbar.

Ein konkurrierend geänderter Eintrag kann nicht still überschrieben werden.
Der Editor zeigt den Konflikt und erhält den Entwurf zum ausdrücklichen Kopieren.
Danach den Editor schließen und den aktuellen Eintrag neu öffnen. Ein
Schreibfehler erhält den bisherigen Plattenstand. Ein verspäteter
Pipeline-Schreibvorgang darf eine jüngere manuelle Fassung nicht ersetzen;
bei identischem Rohtext ist nur die notwendige Fortschreibung des Audioverweises
zulässig, ohne einen bereits entfernten Verweis wieder einzutragen.
