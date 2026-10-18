# Aufnahme pausieren und fortsetzen

**Pausieren** im Menü oder Aufnahmefeld schließt das Mikrofon und hält das Diktat
an. Das orange Feld zeigt **PAUSIERT**, **Mikrofon aus** und die bisherige Audiozeit.
**Fortsetzen** öffnet eine neue Aufnahmephase. **Beenden**, der Start-/Stopp-Hotkey
oder ein Klick auf den freien Feldbereich beendet das gesamte Diktat, auch aus Pause.
Der erste Klick auf die beschrifteten Buttons funktioniert ohne Fokuswechsel.

Audiozeit bedeutet erfasste Samples, nicht verstrichene Zeit. Pausen und die
Vorbereitung des Fortsetzens zählen nicht. Die Abwesenheitserkennung erfasst nur
aktive Stille und beginnt nach Fortsetzen neu. Der Vorlaufpuffer wird ebenfalls
neu begonnen, damit Audio einer alten Phase nicht doppelt erscheint.

Alle Phasen landen ohne Pausenlücke in einer gemeinsamen lokalen WAV-Datei.
Bereits laufende lokale Transkriptionen dürfen während der Pause fertig werden.
Erst **Beenden** fügt alle Segmente in Aufnahme-Reihenfolge zusammen und startet
genau eine logische Bereinigung über den vollständigen Text. Profil, Sprache,
Wörterbuch, Lokalitätsrichtlinie und Aufbewahrung bleiben vom ersten Start eingefroren.
Das ursprüngliche Einfügeziel bleibt erhalten und wird vor dem Einfügen erneut geprüft.

Bei **Zum Sprechen gedrückt halten** beendet Loslassen auch während Pause oder
Fortsetzung das Diktat. Die feste Sicherheitsfrist von fünf Minuten seit dem
Tastendruck läuft weiter. Eine während des Fortsetzens freigegebene Taste darf das
Mikrofon nicht verspätet öffnen. Neue Audiosamples werden erst nach bestätigtem
Fortsetzungsstart angefügt. Schlaf, inaktive Sitzung und Hotkey-Aufzeichnung
brechen den eigenen Hold-Auftrag wie bisher ab.

Fortsetzen verwendet die konfigurierte Geräteauswahl; **Systemstandard** wird neu
aufgelöst. Ist ein ausdrücklich gewähltes Gerät verschwunden oder scheitert das
Fortsetzen, bleiben die bisherigen Aufnahmephasen zur Diagnose erhalten. Schon
erkannte Teile erscheinen als unbereinigter Fehlereintrag, ohne automatische Ausgabe
oder Bereinigung. Die ursprüngliche Datenschutzwahl gilt auch dafür. Ein defekter
WAV-Abschluss zeigt den Dateipfad und bietet keine falsche Audio-Wiederholung.

**Abbrechen** verwirft das gesamte Diktat wie bisher. Ein Fehler beim Löschen
bleibt sichtbar und erhält den Diagnoseverweis. Modus-/Geräteeinstellungen, die
einen Neuaufbau erfordern, bleiben während Pause oder Fortsetzung gesperrt;
Profilwechsel gelten erst für das nächste Diktat.
