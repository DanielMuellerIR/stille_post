# Geplante Erweiterungen für Stille Post

Stand: 2026-10-16. Ausgangsversion: 0.9.20. Die folgenden Funktionen sind geplant; diese Übersicht beschreibt keinen bereits ausgelieferten Funktionsstand. Der aktuelle Projektstatus steht im [Backlog](../backlog.md).

## Sicheres Einfügen und Korrigieren

- Das Ziel eines Diktats beim Aufnahmebeginn festhalten und vor dem Einfügen erneut prüfen. Bei Zielwechsel oder unzureichender Zuordnung den Text mit verständlichem Hinweis zum manuellen Einfügen bereitstellen.
- Eine optionale Ergebnisvorschau und einen schnellen Abruf des letzten Ergebnisses anbieten. Die bestehende Behandlung von Bildschirmfreigabe und Zwischenablage erhalten.
- Ergebnisse im Verlauf korrigieren, Änderungen gegenüber dem Rohtext anzeigen und manuelle Fassungen nachvollziehbar kennzeichnen.
- Bestätigte Korrekturen ins persönliche Wörterbuch übernehmen und gespeicherten Rohtext ausdrücklich erneut bereinigen. Mehrdeutige Ersetzungen eng begrenzen; Zahlen, Verneinungen und Kennungen bleiben geschützt.

## Profile und Verlauf

- Manuell wechselbare Profile für Sprache, Fachbegriffe, Bereinigung und Aufbewahrung anbieten; danach eine optionale Zuordnung nach Zielanwendung ergänzen. Eine laufende Aufnahme behält ihre beim Start gewählten Einstellungen.
- Ausschließlich lokale Bereinigung als ausdrückliche Richtlinie durch die gesamte Endpoint-Kette führen, einschließlich Vorwärmen, Probes und Fallbacks.
- Den Verlauf lokal nach Text und Datum durchsuchen, Fehler filtern und einzelne Einträge sicher löschen.
- Eine wählbare Textaufbewahrungsdauer und Diktate ohne dauerhaften Textverlauf anbieten. Erhaltene Fehleraufnahmen bleiben über sichtbare textfreie Diagnoseverweise erreichbar und folgen einer eigenen ausdrücklich gewählten Löschregel.

## Aufnahme und Diagnose

- Zusätzlich zum Start/Stopp-Schalter eine Betriebsart zum Gedrückthalten anbieten.
- Längere Aufnahmen pausieren und als ein Diktat fortsetzen.
- Eine optionale Rohtextvorschau aus bereits abgeschlossenen Segmenten anzeigen. Sie verspricht keine Wort-für-Wort-Aktualisierung und löst keine zusätzliche segmentweise Bereinigung aus.
- Diagnose und kurzes Testdiktat in der App bereitstellen. GUI und CLI verwenden dieselben Kernprüfungen; Phasenzeiten erklären Start, Transkription und Bereinigung.

## Weitere Eingaben und Formatierung

- Audiodateien per Dateiauswahl und Drag-and-drop lokal transkribieren, mit begrenzten Ressourcen, Fortschritt und Abbruch. Originaldateien bleiben unangetastet.
- Einen ausdrücklich aktivierten Modus für wenige eindeutige gesprochene Formatierungsbefehle ergänzen. Der normale Diktiermodus behandelt solche Wörter weiterhin als Inhalt.
- Die vorhandene worttreue Bereinigung über eine bewusste macOS-Aktion auf markierten Text anwenden; Ergebnisse zunächst prüfen und nur in ein noch passendes Ziel übernehmen.

## Lokale Modelle und iPhone

- Whisper large-v3-turbo, einen geeigneten Parakeet-Kandidaten und Silero-VAD reproduzierbar auf Qualität, Latenz und Ressourcen vergleichen. Alternativen nur bei belegtem Nutzen integrieren; Standardmodell und macOS-Untergrenze werden nicht ohne entsprechende Entscheidung geändert.
- Eine kleine native iPhone-App für Aufnahme, Heimnetzverarbeitung und Ergebnisübernahme ergänzen. Keine Tastatur-Erweiterung und kein Fernzugriff.
- Die native Heimnetzanbindung mit TLS, geprüftem Zertifikats-Fingerabdruck und QR-Kopplung absichern. Default aus, Tokenpflicht, Netzbegrenzung, Warteschlangenlimit und Abbruchverhalten bleiben erhalten. Bestehende Kurzbefehle erhalten einen ausdrücklichen Migrationsweg.
- Lokales Offline-Diktat auf dem iPhone ergänzen. Modellwahl und Machbarkeit zuerst auf dem Zielgerät prüfen; im Offline-Modus wird kein Audio versendet. Eine spätere Übertragung erfolgt ausschließlich auf ausdrückliche Aktion.

## Reihenfolge und Abschluss

Zuerst folgen die offenen Ausgangsabnahmen und sichere Textausgabe. Danach werden Verlauf, Korrektur, Profile, Aufnahmebedienung und zusätzliche Eingaben ergänzt. Die Modellvergleiche gehen möglichen Engine-Änderungen voraus. Die iPhone-App wird in den Stufen Brückenzugriff, sichere Kopplung, Modellverwaltung und Offline-Diktat aufgebaut. Abschließend werden die wesentlichen Kombinationen auf realen Geräten abgenommen und die Nutzung in beiden Sprachen dokumentiert.

Audio bleibt lokal auf dem verarbeitenden Gerät. Die Mac-App sendet weiterhin kein Audio. Mehrere Segmente werden in Aufnahme-Reihenfolge zusammengeführt und genau einmal über den vollständigen Text bereinigt. Datenschutz, Worttreue und der WAV-Lebenszyklus bleiben verbindlich.
