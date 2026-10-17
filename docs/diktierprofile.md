# Diktierprofile

Unter **Einstellungen → Profile** lassen sich Profile anlegen, umbenennen und
löschen. Ein Profil kann Sprache, Wörterbuch, Bereinigung und Aufbewahrung
überschreiben. Jeder Bereich übernimmt zunächst die globalen Einstellungen aus
den übrigen Tabs. Wird die Übernahme ausgeschaltet, beginnt der eigene Bereich
mit einer Kopie der globalen Werte. Spätere globale Änderungen erreichen nur
weiterhin geerbte Bereiche.

Das eigene Wörterbuch ersetzt Begriffe und bestätigte Verhörvarianten gemeinsam;
eine leere Liste ist möglich. Neue Varianten werden weiterhin ausdrücklich im
Verlaufseditor bestätigt und nach denselben engen Regeln geprüft. Dort steht,
welches Wörterbuch die Aktion ändert: das beim Öffnen aktive eigene Wörterbuch
oder bei Vererbung das globale. Ein inzwischen gelöschtes Profil oder entferntes
eigenes Wörterbuch führt zu einem Fehler und schreibt nichts an anderer Stelle.

Das **Standardprofil** gilt, solange im Menü **Standard verwenden** gewählt ist.
Eine manuelle Menüauswahl bleibt über App-Neustarts erhalten. Profilnamen können
sich ändern; Referenzen verwenden unveränderliche UUIDs. Beim Löschen werden
Standard- und manuelle Referenzen auf dieses Profil entfernt. Unbekannte oder
ungültige IDs fallen auf das gültige Standardprofil, anschließend auf globale
Einstellungen zurück. Alte Konfigurationen ohne Profile verwenden unverändert
ihre bisherigen globalen Werte; beim Laden werden keine neuen IDs erzeugt.

Die Aufnahme zeigt Profilname und Sprachcode. Sprache, Bereinigung, Wörterbuch
und Aufbewahrung werden vor dem Start eines Auftrags gemeinsam festgehalten.
Auch ein Profilwechsel während Aufnahme, Transkription, Bereinigung oder einer
wartenden zugelassenen Brückenanfrage ändert ausschließlich folgende Aufträge.
Sprachwechsel benötigen keinen Whisper-Neustart. Hardware, Whisper-Modell und
-Adresse, VAD, Hotkeys, Oberfläche und Brückenzugang bleiben global. Änderungen
an diesen Komponenten lassen sich erst ohne laufende Desktop-Aufträge,
Brückenverbindungen und unbestätigte Ergebnisvorschauen anwenden.

Die Brücke und die Verarbeitungsbefehle der CLI verwenden ebenfalls die aktive
Profilwahl. Die Brücke bewahrt weiterhin keinen Textverlauf auf. Ihr Token,
Netzschutz, Warteschlangenlimit und die strenge lokale Audioverarbeitung bleiben
unverändert. Das vorübergehende Ausschalten des Textverlaufs im Menü hat Vorrang
vor der Profilregel und betrifft folgende Desktop-Aufträge.

**Erneut bereinigen** verwendet das beim ausdrücklichen Start aktive Profil und
den vollständigen unveränderten Rohtext. Eine neue Profilwahl während dieser
Bereinigung verändert ihre Vorschau nicht. Erst die ausdrückliche Übernahme
speichert eine neue Fassung; sie löst kein automatisches Einfügen aus. Vorhandene
Aufbewahrungsregeln bleiben am bestehenden Eintrag erhalten; ihre Fristen werden
dadurch nicht verlängert. Profilwechsel verändern keine bereits gespeicherten
Diktate oder deren Vorfassungen.

Bereinigungsprofile können die vorhandene Endpoint-Kette konfigurieren. Nur der
Text darf an diese Dienste gehen; Audio bleibt lokal. App-Zuordnung und eine
Richtlinie, die auch jeden Textrequest auf Loopback begrenzt, folgen separat.
