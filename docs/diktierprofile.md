# Diktierprofile

Unter **Einstellungen → Profile** lassen sich Profile anlegen, umbenennen und
löschen. Ein Profil kann Sprache, Wörterbuch, Bereinigung, gesprochene Formatierung und Aufbewahrung
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

Die Auswahl folgt der Reihenfolge **manuell → App-Regel → Standardprofil →
globale Einstellungen**. Unter **Einstellungen → Apps** lassen sich Bundle-IDs
einem Profil zuordnen. **App wählen** übernimmt nur die Bundle-ID, keinen Pfad
und keine App-Inhalte. Die Zuordnung vergleicht die vollständige ID einschließlich
Groß-/Kleinschreibung. Unbekannte Apps verwenden das Standardprofil oder globale
Werte. Einstellungen, Verlauf und Menü von Stille Post behalten die letzte externe
Ziel-App; Fenstertexte, Bildschirm und Zwischenablage werden dafür nicht gelesen.

Im Menü aktiviert **Automatisch (App/Standard)** die App-Regeln. Eine manuelle
Menüauswahl hat Vorrang und bleibt über App-Neustarts erhalten. Profilnamen können
sich ändern; Referenzen verwenden unveränderliche UUIDs. Beim Löschen werden
Standard- und manuelle Referenzen sowie App-Regeln auf dieses Profil entfernt.
Fehlt das Ziel einer extern bearbeiteten App-Regel, zeigt die Auswahl den Rückfall
an. Unbekannte oder ungültige IDs fallen auf das gültige Standardprofil, anschließend auf globale
Einstellungen zurück. Alte Konfigurationen ohne Profile verwenden unverändert
ihre bisherigen globalen Werte; beim Laden werden keine neuen IDs erzeugt.

Die Aufnahme zeigt Profilname, Sprachcode und Auswahlgrund. Sprache, Bereinigung, Wörterbuch
und Aufbewahrung werden vor dem Start eines Auftrags gemeinsam festgehalten.
Auch ein Profilwechsel während Aufnahme, Transkription, Bereinigung oder einer
wartenden zugelassenen Brückenanfrage ändert ausschließlich folgende Aufträge.
Sprachwechsel benötigen keinen Whisper-Neustart. Hardware, Whisper-Modell und
-Adresse, VAD, Hotkeys, Oberfläche und Brückenzugang bleiben global. Änderungen
an diesen Komponenten lassen sich erst ohne laufende Desktop-Aufträge,
Brückenverbindungen und unbestätigte Ergebnisvorschauen anwenden.

Die Brücke und die Verarbeitungsbefehle der CLI besitzen keine lokale Ziel-App:
Sie verwenden die manuelle Auswahl, sonst Standardprofil oder globale Werte.
Die Brücke bewahrt weiterhin keinen Textverlauf auf. Ihr Token,
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
Text darf an diese Dienste gehen; Audio bleibt lokal.

## Ausschließlich lokale Verarbeitung

**Einstellungen → Bereinigung → Ausschließlich auf diesem Mac verarbeiten**
begrenzt auch Text auf numerische Loopback-Adressen: IPv4 `127.0.0.0/8` und IPv6
`::1`. DNS-Namen einschließlich `localhost`, LAN-Adressen, Cloud-Ziele und URLs
mit Zugangsdaten sind ausgeschlossen. Entscheidend ist die Adresse, auch bei einem
als Ollama bezeichneten Dienst. Die Richtlinie gilt für Probe, Diagnose, Warm-up,
Streaming, Wiederholung, Komplettantwort und die gesamte Fallback-Kette. Nicht
lokale Redirects werden vor dem Folgen gesperrt; Systemproxies werden deaktiviert.
Ein lokaler Dienst kann selbst Verbindungen aufbauen; seine Konfiguration liegt
außerhalb der von Stille Post erzwungenen Transportgrenze.

Eigene Bereinigungsbereiche dürfen die lokale Richtlinie ausdrücklich überschreiben.
Alte eigene Bereiche ohne dieses Feld übernehmen weiterhin die globale Richtlinie.
Fehlt das Feld auch global, bleibt das bisherige Verhalten erhalten; ein vorhandenes
falsch typisiertes Feld aktiviert vorsichtshalber die lokale Grenze. Lokale
OpenAI-kompatible Dienste benötigen keinen API-Key; Stille Post greift dafür nicht
auf den Schlüsselbund zu und überträgt keinen Authorization-Header.

Ohne zulässigen erreichbaren Dienst bleibt der transkribierte Text verfügbar:
Die deterministische Rohtext-Nachstufe repariert Satzzeichen/Großschreibung, die
Anzeige erklärt den lokalen Rückfall. Eine Neubereinigung meldet den Ausfall und
behält die bisherige Fassung. Ein Profil- oder Fokuswechsel kann die Richtlinie
eines bereits gestarteten Auftrags nicht lockern.

Die [gesprochene Formatierung](gesprochene-formatierung.md) besitzt einen eigenen
vererbbaren Schalter. Alte Profile übernehmen den standardmäßig ausgeschalteten
globalen Wert; ein eigener Bereinigungsbereich verändert diesen Schalter nicht.
