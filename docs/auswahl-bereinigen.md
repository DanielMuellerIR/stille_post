# Ausgewählten Text bereinigen

Markiere Text in einer anderen App und wähle im Stille-Post-Menü
**Ausgewählten Text bereinigen …**. Der macOS-Dienst **Ausgewählten Text mit
Stille Post bereinigen** bietet denselben bewussten Einstieg im Dienste-Menü der
Text-App. Es gibt dafür kein zusätzliches globales Tastenkürzel.

Die Vorschau zeigt ursprüngliche Auswahl und Ergebnis nebeneinander, Ziel-App,
Profil, Sprache und Herkunft. Sie verwendet dieselbe worttreue Bereinigung wie
Diktate. Das beim Start für die Ziel-App aufgelöste Profil bleibt bis zum Abschluss
fest, auch wenn die manuelle Auswahl oder App-Regeln währenddessen geändert werden.
Die lokale Richtlinie begrenzt auch hier alle Textanfragen und Fallbacks auf diesen
Mac. Ohne LLM bleibt die deterministische Nachstufe beziehungsweise ausdrücklich
aktivierte gesprochene Formatierung verfügbar.

**Auswahl ersetzen** ist eine gesonderte Bestätigung. Stille Post gibt zuerst den
Tastaturfokus der Vorschau frei und prüft die ursprüngliche App-Instanz, das
fokussierte Textfeld, den Auswahlbereich und den genauen Text erneut. Die Ziel-App
muss noch vorn sein. Eine zwischenzeitlich aktivierte andere App sperrt Ersetzen
für diesen Auftrag, auch nach Rückkehr. Eine geänderte Auswahl wird nicht durch
Zurücksetzen des alten Auswahlbereichs erzwungen. Ein neuer Auftrag benötigt eine
neue bewusste Aktion.

Manche Textfelder geben ihre Auswahl nicht frei oder unterstützen kein direktes
Ersetzen. Die Anzeige nennt diese Beschränkung. Über den ausdrücklichen macOS-
Dienst kann dessen mitgelieferte Auswahl trotzdem als Vorschau verarbeitet werden;
ohne überprüfbares Ziel bleibt Ersetzen gesperrt. Ist der Ursprung des Diensts nicht
sicher verifizierbar, bleibt der Auftrag ausschließlich lokal und verwendet das
manuelle beziehungsweise Standardprofil. Für eine überprüfte Übernahme die
ursprüngliche App wählen und die Menüaktion neu starten. **Ergebnis kopieren** ist eine
eigene ausdrückliche Aktion. Ein fehlgeschlagenes oder nicht bestätigbares Einsetzen
wird nicht automatisch wiederholt; die Vorschau bleibt zur Prüfung verfügbar.

Abruf und direktes Ersetzen verwenden keine Zwischenablage. Der Dienst nimmt nur
seinen eigenen ausdrücklichen Auswahltransfer entgegen; der allgemeine Clipboard-
Inhalt ist keine Ersatzauswahl. Auswahl und Ergebnis werden nur für diesen Auftrag
im Arbeitsspeicher gehalten, nicht im Diktatverlauf. Der letzte reguläre Diktattext
bleibt davon unabhängig. **Schließen** verwirft den Auftrag einschließlich später
ankommender Antworten. Die Verarbeitung benötigt weder Mikrofon noch Whisper.

Die Auswahl ist auf 8 KiB UTF-8 begrenzt. Beim direkten Zugriff werden geschützte
Textfelder abgewiesen. Ohne verifiziertes Dienstziel ist die Art des ursprünglichen
Felds unbekannt; der ausdrücklich übertragene Text bleibt ausschließlich lokal
und kann die Auswahl nicht ersetzen.
Die macOS-Accessibility-Schnittstelle bietet keinen atomaren Vergleich-und-
Ersetzen-Aufruf; Prüfung und Schreiben folgen deshalb mit begrenzter Wartezeit
unmittelbar aufeinander. Ein tatsächlich nicht bestätigbarer Schreibvorgang wird
als solcher gemeldet, statt Erfolg vorzugeben.

Technischer Dienstvertrag: `NSSendTypes` überträgt Text; `NSReturnTypes` fehlt
absichtlich. Dadurch fügt macOS keine Modellantwort beim Rücklauf des Diensts ein.
Siehe [Apples Services-Dokumentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html).
