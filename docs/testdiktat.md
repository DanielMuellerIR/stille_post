# Ein kurzes Testdiktat

**Testdiktat …** im Menü oder in der Diagnose öffnet zunächst die Vorbereitung.
Profil, Sprache, Lokalität und Aufbewahrung stehen vor dem Start sichtbar da.
**Aufnahme starten** ist die ausdrückliche Zustimmung zum Mikrofonzugriff.
Fehlt ein Eingabegerät oder ist der Zugriff verweigert, führen passende Aktionen
zu den Einstellungen. Eine noch nicht erteilte Mikrofonfreigabe fragt macOS erst
beim ausdrücklichen Start an.

**Beenden** verarbeitet das bisher erfasste Audio. Nach etwa 20 Sekunden endet
die Aufnahme automatisch. **Abbrechen** verwirft den eigenen Test, auch während
Vorbereitung oder Verarbeitung. Fenster schließen sowie Schlaf und
Sitzungsunterbrechung stoppen einen aktiven Test. Der Aufnahme- und Hold-Hotkey
startet oder beendet den aktiven Test nicht; seine eigenen Buttons bleiben maßgeblich.

Die Vorschau fügt nichts automatisch ein und verändert den letzten regulären
Text nicht. Sie zeigt zutreffend bereinigten Text, ausgeschaltete Bereinigung oder
Rohtext-Rückfall. Text lässt sich ausdrücklich auswählen und kopieren.
**Neuen Test vorbereiten** verwirft die Vorschau und lädt die aktuell angewendeten
Einstellungen. Haben sie sich seit der Vorbereitung geändert, ist vor Aufnahme
erneut zu aktualisieren und zu prüfen.

Die Aufbewahrung des sichtbaren Profils gilt auch für den Test. Bei aktivem
Textverlauf entsteht ein normaler Eintrag mit unverändertem Rohtext. Ohne
Textverlauf bleibt die Vorschau flüchtig; Fehler dürfen textfreie lokale
Audioverweise hinterlassen. Erfolgs-Audio wird gelöscht. Fehleraudio bleibt nach
der Profilregel erhalten; bei Fehlern lässt sich der Aufnahmeordner öffnen.
Audio geht ausschließlich an den lokalen Whisper. Optional geht erst der fertige
Text an konfigurierte Bereinigungsdienste; lokale Profile schließen entfernte
Endpunkte auch für Warm-up, Probes und Fallbacks aus.

Der Test verwendet dieselbe Diktier-Engine und denselben Whisper wie reguläres
Diktat. Alle Segmente werden geordnet zusammengefügt und erhalten genau einen
logischen Bereinigungsauftrag über den vollständigen Text. Profilwechsel während
des Tests betreffen den nächsten Auftrag. Reguläres Diktat und offene
Ergebnisvorschauen können den Teststart blockieren; sie werden nicht verdrängt.

Die **Phasenzeiten** bedeuten:

- **Vorbereitung:** vom Startversuch bis zur bestätigten Aufnahme oder dessen Abbruch.
- **Erfasste Audiozeit:** tatsächlich aufgenommene Samples.
- **Lokale Transkription:** Summe abgeschlossener lokaler Anfragen. Sie können
  schon während der Aufnahme und untereinander überlappen.
- **Bereinigung:** der vollständige Bereinigungsauftrag einschließlich nötiger Rückfälle.

Diese Werte lassen sich nicht zu einer Gesamtdauer addieren. **Phasenbericht
kopieren** enthält nur Version, Prüfzeit, feste Zustands-/Herkunftscodes, Zeiten
und Datenschutzflags. Diktate, Fehlerbeschreibungen, Profilnamen, Geräte,
Adressen, Schlüssel und Dateipfade fehlen darin.
