# Zum Sprechen gedrückt halten

Unter **Einstellungen → Allgemein → Hotkey-Betriebsart** stehen **Umschalten**
und **Zum Sprechen gedrückt halten** zur Wahl. Alte Konfigurationen bleiben bei
Umschalten. Das globale JSON-Feld `hotkeyMode` enthält `toggle` oder `hold`;
fehlende oder unbekannte Werte verwenden `toggle`. Profile verändern die Betriebsart
nicht. Der Abruf-Hotkey bleibt eine getrennte Kombination.

Bei Umschalten startet ein Tastendruck, der nächste stoppt. Bei Hold startet eine
frische Betätigung der registrierten Kombination. Loslassen der Haupttaste oder
einer erforderlichen Zusatztaste stoppt die Aufnahme. Wird schon während der
Vorbereitung losgelassen, bricht der Start ab. Der aktuelle Tastenstatus wird
zusätzlich vor dem Audiostart geprüft, auch ohne Freigabecallback. Falls der
Hardwarestart bereits läuft, wird unmittelbar danach wieder gestoppt und sein
Zwischenaudio verworfen; daraus entsteht kein Diktat. Ein Fehler beim Verwerfen
wird gemeldet und behält die Aufnahme zur Diagnose. Die orange Vorbereitung und die rote Aufnahme sind
klar unterscheidbar. Das Aufnahmefeld zeigt zusätzlich **Zum Beenden loslassen**.

Tastenwiederholungen starten keine zweite Aufnahme. Nach Abbruch, Fehler, Auto-Stopp
oder Loslassen eines Modifiers muss zunächst die Haupttaste losgelassen werden.
Erneutes Drücken während laufender Verarbeitung wird ignoriert. Eine Aufnahme,
die über das Menü gestartet wurde, gehört nicht automatisch einem Hold-Tastendruck:
Menü und Overlay bleiben als ausdrückliche Stoppwege verfügbar. Ein Klick auf das
Vorbereitungsfeld bricht den Start ab.

Carbon-Freigaben werden durch eine Tastenstatus-Prüfung alle 100 ms ergänzt. Nach
fünf Minuten durchgehendem Halten stoppt eine Aufnahme sicherheitshalber; eine noch
wartende Vorbereitung wird abgebrochen. Der Hinweis erklärt den Sicherheitsstopp.
Schlaf, eine inaktive Sitzung oder das Aktivieren eines Einstellungs-Recorders
brechen einen eigenen Hold-Auftrag ab. Die Registrierung benötigt keinen Event-Tap. Der sichere Tastenstatus für Hold
verwendet die bereits zum automatischen Einfügen benötigte Bedienungshilfenfreigabe
(oder eine schon erteilte Eingabeüberwachungsfreigabe). Fehlt der Zugriff, zeigt
Hold einen Hinweis und startet kein Audio. Umschalten und Menü bleiben verfügbar.
Es wird keine zusätzliche Freigabe angefordert.
Es werden nur der Zustand der registrierten Taste und erforderliche Modifier gelesen.

Beide Recorder übernehmen auch bereits registrierte Kombinationen, ohne ein Diktat
oder den Ergebnisabruf auszulösen. Gleiche Aufnahme- und Abrufkombinationen sperren
Speichern mit einer Fehlermeldung. Ein Moduswechsel lässt sich erst übernehmen,
wenn Desktop, Brücke und unbestätigte Ergebnisse ruhen. Modus- und Kombinationswechsel
bauen die Engine nicht neu auf; geänderte Kombinationen registrieren nur die Hotkeys neu.

Sprache, Wörterbuch, Bereinigung, lokale Richtlinie und Aufbewahrung werden weiterhin
beim Auftragsstart gemeinsam eingefroren. Das vollständige Diktat erhält genau einen
logischen Bereinigungsauftrag. Profil- und App-Regelwechsel beeinflussen nur folgende
Aufträge; die Brücke verwendet keinen lokalen Hotkey.
