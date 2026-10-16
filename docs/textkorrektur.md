# Ergebnistext korrigieren und vergleichen

**Verlauf → Bearbeiten** öffnet den Editor für einen erfolgreichen Eintrag.
Unter **Text** lässt sich das Ergebnis ändern. **Speichern** übernimmt die
Korrektur; **Abbrechen** verwirft den ungespeicherten Entwurf. **Entwurf kopieren**
kopiert ausdrücklich den angezeigten Text. Die Kopieraktion in der Verlaufszeile
verwendet immer die aktuell gespeicherte Ergebnisfassung.

Der Whisper-Rohtext bleibt unverändert. Die erste bestätigte Änderung erhält
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

## Wörterbuch aus Korrekturen

Unter **Text → Ins Wörterbuch …** lässt sich die markierte Schreibweise übernehmen
oder eine Schreibweise ausdrücklich eingeben. Erst die Bestätigung und
**Wörterbucheintrag speichern** machen sie dauerhaft. Der Textentwurf wird dabei
nicht gespeichert. Wörterbucheinträge bleiben unabhängig vom Verlauf erhalten;
sie sind unter **Einstellungen → Bereinigung** editierbar.

Identische Einträge werden nicht erneut hinzugefügt. Eine abweichende Schreibweise
mit demselben Namen ohne Beachtung der Großschreibung erzeugt einen Konflikt;
den vorhandenen Eintrag dann in den Einstellungen bearbeiten. Gleichzeitige
Wörterbuchaktionen führen ihre Änderungen auf dem frischen Dateistand zusammen.
Offene Einstellungen können einen inzwischen geänderten Stand nicht überschreiben.
Neue Schreibweisen gelten ab dem nächsten Auftrag, auch für die iPhone-Brücke.
Laufende und bereits zugelassene Brückenaufträge behalten ihren bisherigen
Wörterbuchstand. Reine Wörterbuchänderungen in den Einstellungen beenden keine
laufende Aufnahme.

Optional ist eine ausdrücklich bestätigte Verhörvariante möglich, etwa
**Whis per → Whisper**. Sie gilt global und ersetzt ausschließlich die genaue
Mehrwortfolge an Wortgrenzen, ohne unscharfe Suche oder verkettete Ersetzungen.
Die Quelle braucht zwei oder drei durch jeweils ein Leerzeichen getrennte Teile
mit mindestens drei Buchstaben. Das Ziel muss im Wörterbuch stehen, 6–40 Buchstaben
lang sein und entweder ein vorbelegter Fachbegriff oder eine Schreibweise mit
Binnen-Großbuchstaben wie **GitHub** sein. Zusammengeschrieben darf die Quelle um
höchstens einen Buchstaben vom Ziel abweichen. Zahlen, Versionskennungen,
Verneinungen und häufige Funktionswörter sind als Regeln ausgeschlossen;
Einwortregeln wie **Rack → RAG** sind hier nicht möglich. Überlappende Quellen
werden abgewiesen. Bis zu 500 Begriffe mit jeweils 80 Zeichen und 100 Varianten
sind erlaubt. Varianten lassen sich einzeln in den Einstellungen löschen;
vor dem Entfernen einer Zielschreibweise zuerst ihre Varianten entfernen.

Die Variante wird nur für die Bereinigungsanfrage angewandt. Der gespeicherte
Rohtext bleibt unverändert. Bei Netzwerkfehler oder verworfener Modellantwort
liefert der normale Diktierablauf weiterhin den ursprünglichen Rohtext mit
deterministisch reparierten Satzzeichen, ohne Wörter aus der Variantenregel.

## Gespeicherten Rohtext neu bereinigen

**Neu bereinigen → Rohtext jetzt neu bereinigen** verwendet den gesamten
unveränderlichen Rohtext und die frisch geladene Konfiguration. Dazu ist kein
Audio erforderlich. Bereinigung muss eingeschaltet sein; Text kann an die dort
eingestellten Dienste gehen. Ein vollständiger Bereinigungslauf verwendet die
bestehenden Wiederholungs- und Ausweichregeln; es gibt keine Bereinigung pro Segment.

Die neue Fassung wird zuerst nur angezeigt. **Neue Fassung übernehmen** speichert
sie und ersetzt den aktuellen Entwurf. **Neue Fassung verwerfen**, Abbruch oder
Schließen verwerfen sie; Fehler und Rohtext-Rückfall lassen die bisherige Fassung
ebenfalls erhalten. Nichts wird automatisch kopiert oder eingefügt.
Eine übernommene Neubereinigung wird als automatisch bereinigt gekennzeichnet,
auch nach einer manuellen Korrektur. Die ursprüngliche Ausgabe und höchstens drei
Vorfassungen bleiben erhalten. Dieselben Konflikt-, Lösch- und Aufbewahrungsregeln
gelten auch zwischen Anfrage und Übernahme. Verspätete Pipelineupdates können
bestätigte Neubereinigungen ebenfalls nicht überschreiben.
