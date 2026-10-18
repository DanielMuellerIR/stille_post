# Audiodateien lokal transkribieren

**Audiodatei transkribieren …** im Menü öffnet die Importansicht. **Audiodatei auswählen …** übernimmt eine einzelne lokale Datei. Vom System lesbare Formate werden unterstützt; WAV, AAC/m4a und AIFF sind geprüft. Die Grenze liegt bei fünf Minuten und 50 MiB, gemessen auch am tatsächlich dekodierten Audio.

Vor **Transkribieren** stehen Dateiname, Profil, Sprache, lokale Bereinigungsrichtlinie und konkrete Aufbewahrungsfristen sichtbar da. Wenn der Zeiger auf dem Dateinamen ruht, erscheint der vollständige Pfad. Änderungen am Profil erfordern vor einem neuen Auftrag **Profil aktualisieren**. Ein gestarteter Auftrag behält seine Konfiguration bis zum Abschluss. Ein Mikrofon oder Mikrofonrecht wird dafür nicht benötigt.

Die App liest die Originaldatei und erzeugt eine eigene normalisierte Arbeitskopie. Änderungen an Größe, Änderungszeit oder Dateiidentität während der Vorbereitung brechen den Import ab. Lokale VAD-Segmente werden geordnet transkribiert; erst der vollständige Text erhält einen logischen Bereinigungsauftrag. Stille beendet eine Datei nicht vorzeitig. Audio geht ausschließlich an den lokalen Whisper; optional verlässt nur fertiger Text den Rechner. Lokale Profile filtern auch Warm-up, Probes und Fallbacks.

Das Ergebnis erscheint in einer auswählbaren Vorschau und gemäß Profil im Verlauf. **Ergebnis kopieren** ist eine ausdrückliche Aktion. Der Import fügt nichts automatisch ein und überschreibt den letzten regulären Text nicht. Herkunft und Rohtextfallback bleiben sichtbar; unvollständiger Teiltext ist entsprechend gekennzeichnet. Ohne dauerhaften Textverlauf bleibt die Vorschau flüchtig.

**Abbrechen**, Fenster schließen, Schlaf und Sitzungsunterbrechung stoppen den eigenen Auftrag. Die App wartet auf das Schließen von Decoder und Writer, bevor sie die Arbeitskopie entfernt; auch geregeltes Beenden wartet auf die nötige Speicherung. Währenddessen kann kein neuer Aufnahme-/Test-/Importauftrag den laufenden verdrängen. Bereits abgeschlossene Vorschaufenster beenden keinen späteren fremden Auftrag.

Erfolg entfernt nur die eigene Arbeitskopie. Fehleraudio bleibt lokal unter der Profilregel erreichbar. Unvollständige oder ungültige Kopien sind für eine erneute Transkription gesperrt, auch über die CLI; dafür die unveränderte Originaldatei erneut importieren. Ein vollständig vorbereitetes Audio kann bei Transkriptionsfehlern über den Verlauf erneut verarbeitet werden. Ältere Verlaufseinträge behalten ihr bisheriges Verhalten.
