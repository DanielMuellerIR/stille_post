# Ergebnis vor dem Einfügen prüfen

Ab Version 0.9.23 lässt sich unter **Einstellungen → Allgemein → Ergebnis** die
Vorschau einschalten. Standardmäßig wird ein fertiges Diktat weiterhin direkt
über die bestehende Zielprüfung ausgegeben.

Die automatische Vorschau zeigt den vollständigen Text, ohne den Tastaturfokus
zu übernehmen. Weitergetippter Text und Return bleiben dadurch in der bisherigen
App. Ein Klick in die Vorschau oder der Abruf-Hotkey fokussiert sie ausdrücklich.

- **Einfügen** beziehungsweise ⌘↩ im fokussierten Panel prüft das beim
  Aufnahmebeginn erfasste Ziel erneut. Bei Zielwechsel oder fehlender eindeutiger
  Zuordnung bleibt der Text zum manuellen Einfügen in der Zwischenablage.
- **Kopieren** beziehungsweise ⌘⇧C kopiert den vollständigen Text.
- **Verwerfen**, ⌘. oder Schließen gibt den Text nicht aus.

Ein Rohtext-Rückfall bleibt sichtbar gekennzeichnet. Die Vorschau startet weder
eine zweite Transkription noch eine weitere Bereinigung.

**Letzten Text anzeigen** im Menü oder der separate Hotkey ⌘⌥R öffnet das zuletzt
akzeptierte Ergebnis erneut. Ein bereits offenes Ergebnis wird damit fokussiert.
Der Abruf-Hotkey ist in den allgemeinen Einstellungen unabhängig vom Aufnahme-
Hotkey einstellbar; beide müssen verschieden sein. Während einer laufenden
Aufnahme oder Verarbeitung wird der Abruf ignoriert.

Akzeptiert sind direkt ausgegebene Ergebnisse sowie ausdrücklich eingefügte oder
kopierte Vorschauergebnisse. Verwerfen, Stille, Fehler und Abbruch ersetzen den
vorherigen Text nicht. Beim Abruf wird das dann aktive Textfeld als neues Ziel
erfasst. Automatisches Absenden ist weiterhin ausgeschlossen.

Der letzte Text bleibt ausschließlich im Arbeitsspeicher bis zum App-Ende. Das
ist unabhängig vom bestehenden dauerhaften Diktatverlauf: Das Verwerfen einer
Vorschau löscht keinen dort bereits gespeicherten Eintrag.
