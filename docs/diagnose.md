# Einrichtung prüfen

**Diagnose öffnen …** im Menü oder unter **Einstellungen → Allgemein** prüft die
gespeicherte Konfiguration. Änderungen in den Einstellungen zuerst speichern.
Das Fenster zeigt das geprüfte Profil und die Sprache. Ein neuer Prüflauf löst die
aktuelle manuelle, App- oder Standardauswahl neu auf; ein laufender Prüflauf behält
seine Auswahl. **Abbrechen** verwirft auch später eintreffende Antworten.

Die Diagnose startet keine Aufnahme, keinen Server und keinen Download. Sie
ändert keine Rechte oder Dienste. Die Buttons an einem Befund öffnen die passenden
App- oder Systemeinstellungen. Dort sind Änderungen weiterhin ausdrückliche Aktionen.

- **Mikrofon:** Freigabe und Verfügbarkeit des gewählten Geräts. Eine noch nicht
  angefragte Freigabe wird erst beim ausdrücklichen Aufnahmestart angefragt.
- **Whisper:** Die strukturierte `/health`-Antwort muss ein geladenes Modell
  bestätigen. Ein offener Port oder eine fremde Webseite genügt nicht. Einen schon
  ladenden Whisper wartet der normale Diktatstart ab, ohne einen zweiten zu starten.
- **Modell und Selbststart:** Ein laufender Server braucht seine Startdateien für
  das aktuelle Diktat nicht. Fehlende Dateien sind dann Hinweise für den nächsten
  Kaltstart. Ohne laufenden Server braucht Selbststart ein ausführbares Programm
  und eine eigene Modelldatei. Ein Verweis auf einen fremden Cache bleibt unsicher.
  Ohne Selbststart ist der nicht bereite Server der aktive Blocker.
- **Bereinigung:** Primärdienst und Fallbacks werden in Reihenfolge bewertet. Bei
  Ollama wird auch das Modell in der gültigen Modellliste geprüft. Ein ausgefallener
  Primärdienst bei nutzbarem Fallback ist ein Hinweis. Ohne nutzbaren Dienst bleibt
  der sichere Rohtext-Rückfall. Ausgeschaltete Bereinigung ist kein Fehler.
- **Externe Textdienste:** Adresse, Modellname und erforderlicher Schlüssel können
  eingerichtet sein, ohne dass der Dienst geprüft wurde. Das bleibt ausdrücklich
  unbestätigt; die Diagnose sendet keinen Textauftrag. Lokale Profile schließen
  unzulässige Endpunkte vor jeder Probe oder Schlüsselprüfung aus.
- **Bedienungshilfen:** Automatisches Einfügen benötigt Freigabe. Manuelles Einfügen
  bleibt möglich. Der Haltbetrieb braucht zusätzlich einen lesbaren Tastenstatus.
- **Brücke:** Bei eingeschalteter Brücke werden Tokenzugriff und der tatsächliche
  Listenerstatus geprüft. Eine ausgeschaltete Brücke ist kein Fehler.

**Bericht kopieren** enthält nur Version, Prüfzeit und feste Befundcodes/Zustände.
Adressen, Dateipfade, Profilnamen, Schlüssel, Tokens und Diktate sind darin nicht
enthalten. Die Prüfung fragt konfigurierte Textdienste nur nach ihrem Status;
Audio wird weder aufgenommen noch übertragen.

**Testdiktat …** öffnet die [ausdrückliche Testaufnahme](testdiktat.md) mit
Ergebnisvorschau und getrennten Phasenzeiten. Die Aufnahme beginnt erst nach dem
sichtbaren Start; der Diagnosebericht enthält weiterhin keinen Diktattext.

`stillepost-cli doctor` verwendet denselben Kern. Systemrechte und der Listener
gehören zum jeweiligen App-Prozess; ohne dessen Kontext weist die CLI sie als
unbestätigt aus. Exit 0 bedeutet keine erkannten aktiven Probleme, Exit 1 meldet
Probleme; Hinweise und unbestätigte Befunde bleiben ausdrücklich sichtbar.

Die Health-Semantik folgt dem [Whisper-Server](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/server.cpp):
`status=ok` bei HTTP 200, `status=loading model` bei HTTP 503.
