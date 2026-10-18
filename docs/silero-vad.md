# Optionale Sprachaktivitätserkennung mit Silero

Seit 0.9.40 kann unter **Einstellungen → Aufnahme → Sprachaktivität erkennen**
Silero gewählt werden. **Pegel (RMS)** bleibt Standard. Alte oder unbekannte
Konfigurationswerte laden RMS; in JSON lautet die optionale Auswahl
`"vad": { "detector": "silero" }`.

Die Schaltfläche **Silero-Modell laden und prüfen** beschafft ausdrücklich
1.063.425 Byte von Hugging Face. Beim Aufnahmestart gibt es keinen Download.
Alle fünf Dateien haben feste Größen und SHA-256-Hashes. Der Modellstand ist
Silero 6.2.1 CoreML, Revision
`b419383c55c110e2c9271fa6ee0ea83d03c70d96`; Quellen und Lizenz stehen in
[THIRD-PARTY.md](../THIRD-PARTY.md) und im
[Vergleichsbericht](asr-vad-vergleich.md). Eine abgebrochene Installation entfernt
nur ihre eigene Zwischenkopie. Ein beschädigtes vorhandenes Modell wird bei
Neuinstallation als `.silero-invalid-…` im Modellordner erhalten.

Ohne vollständiges nutzbares Modell oder bei einem Inferenzfehler übernimmt RMS
für die Aufnahmephase. Die Pegelschwelle bleibt daher auch bei Silero relevant.
Aufnahmeoverlay und Testdiktat nennen den Rückfallgrund. Nach Pause/Fortsetzen
wird das Modell erneut vorbereitet. Eine geänderte Detektorauswahl gilt erst
für das nächste Diktat; die laufende Sitzung behält ihren Startstand.

## Ablauf und Plattform

Die direkte CoreML-Anbindung benötigt kein FluidAudio-SDK. Das Produkt bleibt
bei macOS 13. Die Modellmetadaten nennen macOS 12; die Anbindung kompiliert für
macOS 13. Ein tatsächlicher macOS-13- oder Intel-Gerätelauf ist nicht belegt.
Kann CoreML das Modell nicht laden, bleibt RMS verfügbar. Die Inferenz nutzt
bewusst die CPU; daraus folgt kein Anspruch auf die Latenzen des früheren
Vergleichs mit CPU/Neural Engine.

Silero erhält 4.096 neue 16-kHz-Monosamples (256 ms), 64 Kontextsamples und zwei
Rekurrenzzustände mit je 128 Werten. Die Schwelle 0,85 stammt aus dem Vergleich.
Ein positives Fenster behält seine Samples vollständig. Das letzte Teilfenster
wird ausschließlich für die Inferenz mit Nullen ergänzt; WAV und Segmentdauer
enthalten nur empfangenes Audio. Segmentgrenzen erhalten den Modellzustand;
neue Aufnahmephasen nach einer Pause beginnen ohne alten Kontext.

Vor-/Nachlauf, Mindestsprachdauer, Segmentgrenzen und Auto-Stopp verwendet die
bestehende Segmentierung. Pausen und Auto-Stopp haben mit Silero eine Auflösung
von 256 ms. Die Pegelanzeige bleibt unabhängig davon bei 30 ms. Nach einem
Inferenzfehler wird das gesamte noch unverarbeitete Fenster erneut in
30-ms-RMS-Frames bewertet. Der Rückfall lässt keine Samples aus und zählt einen
Klick nicht pauschal als 256 ms Sprache.

Audio bleibt auf dem lokalen Gerät. Die geordneten Segmente gehen weiterhin
an Whisper; erst der vollständige Text erhält genau eine Bereinigung.
Live-Rohtext, Pause/Fortsetzen, Datenschutz und WAV-Lebenszyklus bleiben erhalten.

## Prüfung und Grenzen

Der Produktdetektor wird mit dem unveränderten gehashten AP17-Korpus geprüft.
Der Regressionsadapter `scripts/fixtures/silero-vad-regression.swift` nimmt
Korpusordner, Modellordner und Ergebnisdatei entgegen. Er prüft Originalsamples
innerhalb der tatsächlich gelieferten Segmentgrenzen. Die Pipelineprobe
`scripts/fixtures/silero-pipeline-e2e.swift` verwendet leise Sprache und
Fachbegriffe in zwei Aufnahmephasen mit echtem Whisper und einer Gesamtbereinigung.

Am 2026-10-18 behielt Silero auf Apple M5 Max und Apple M1 jeweils
2.883.360 von 2.883.360 markierten Aktivitätssamples. Stille, Klicks und reines
Rauschen ergaben keine Sprachsegmente. RMS verlor die beiden leisen Dateien
und akzeptierte Rauschen. Ein Korpusdurchgang mit neuer Initialisierung je
Datei dauerte mit Silero 4,892 s / 4,965 s; das ist eine andere Messgrenze als
im SDK-Vergleich und keine Mikrofonlatenz. Neutrale Einzelwerte stehen in
[product-vad-results.json](benchmarks/asr-vad/product-vad-results.json).

Kernprüfungen decken Migration, beschädigte/fehlende Modelle, Integrität,
Installationsabbruch, Fenster-Rückgabe an RMS, Teilfenster, Auto-Stopp,
Pegelanzeige, Startsnapshots und Abbruch während Modellvorbereitung ab.
Das Modell wird für diese Tests ausdrücklich bereitgestellt; sie laden nichts
selbstständig aus dem Netz.

Die Sprachdateien sind künstlich. **Menschliche Mikrofonabnahme bleibt offen**,
insbesondere kurze/leise Wörter, Tastenklicks, Rauschen und lange Pausen mit
realen Stimmen und Geräten. Das ist ein Grund für die optionale Auswahl, kein
Beleg für einen allgemeinen Qualitätsgewinn oder eine Defaultumstellung.
