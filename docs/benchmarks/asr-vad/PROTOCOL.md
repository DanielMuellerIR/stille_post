# Lokaler ASR-/VAD-Vergleich

Festgelegt am 2026-10-18 vor den Messungen. Reiner Vergleich, keine
Produktabhängigkeit und keine Änderung der App-Konfiguration.

## Eingabe

`corpus.json` definiert 24 künstliche DE/EN-Sprachfälle und drei Störfälle.
Lokale macOS-Stimmen Anna/Samantha, 155 Wörter/min, PCM16 mono 16 kHz.
Normale Sprache wird auf −22 dBFS RMS gebracht, leise Sprache auf −52 dBFS.
Weißes Rauschen: −40 dBFS RMS, Seed 1729. 0,5 s Randstille, im Pausenfall
1,2 s zwischen den acht Teiläußerungen. Lange Fälle wiederholen acht festgelegte
Sätze dreimal. Generierte WAVs und ihre SHA-256 bilden den verbindlichen
Eingabesatz; erneute Synthese kann nach einem OS-/Stimmenupdate abweichen.
WAVs auf einem zweiten Gerät kopieren, dort nicht neu synthetisieren.

Referenzen bleiben einschließlich Selbstkorrektur und gesprochener Befehle
wörtlich. WER ignoriert Großschreibung und Interpunktion, erhält aber Wort- und
Zahlenschreibweisen. CER verwendet dieselben normalisierten Wörter einschließlich
Leerzeichen. Ziffern statt Zahlwörtern zählen daher mechanisch als Korrekturen;
die gesonderte Bedeutungsprüfung unterscheidet harmlose Schreibweise von falschem
Wert. Minimale Wortkorrekturen sind Levenshtein-Operationen, keine gemessene
menschliche Bearbeitungszeit. Zahlen, Negationen, Versionen, Fachbegriffe,
Namen, Selbstkorrekturen und Befehle werden zusätzlich gegen die Referenz gelesen.

## Bedingungen und Messgrößen

ASR erhält identische feste 15-s-Segmente ohne VAD-Filter. Sprache bei Whisper
explizit DE/EN, Temperatur 0; Parakeet v3 verwendet seine automatische Sprache.
Kein Prompt, Wörterbuch, ITN oder Cleanup. Frischer Decoderzustand je Segment.
Segmenttexte werden in Reihenfolge mit Leerraum verbunden. Erfasst werden auch
leere Segmente und Anfang/Mitte/Ende der langen Fälle. Störfälle zählen separat,
nie als WER mit einem Nenner von null.

Drei neue Prozesse messen Prozesskaltstart mit vorhandenem Modell und weiterhin
vorhandenen OS-/CoreML-Caches: Initialisierung plus erster DE-Kurzfall. Das ist
kein Bootkaltstart. Anschließend eine separate Priming-Anfrage und drei vollständige
Warmdurchgänge in einem Prozess. Keine parallele Inferenz. Der Dateilauf misst
Stopp-bis-Rohtext als Verarbeitung nach vollständiger Bereitstellung der Datei;
laufende Aufnahme, vorgezogene Transkription, Cleanup und Einfügen fehlen.
Speicher: Prozessspitze bei Parakeet/Silero aus `getrusage`; Whisper-RSS durch
regelmäßiges `ps`-Sampling als beobachtete Untergrenze. ANE-/Metal-Speicher wird
damit nicht vollständig erfasst. Geräte und Laufbedingungen getrennt berichten.

VAD wird separat auf demselben PCM geprüft: unveränderter Produkt-`VadSegmenter`
mit Defaultwerten und Silero 6.2.1 CoreML/FluidAudio 0.17.7 mit Schwelle 0,85,
256-ms-Fenstern, Mindeststimme 0,25 s, Pause 0,7 s, Padding 0,25 s, Limit 30 s.
Die Unterschiede der Segmentierungsregeln bleiben sichtbar. Die bekannte
synthetische Sprachaktivität ist eine Energie-Maske der unveränderten sauberen
TTS-Aufnahme in 30-ms-Frames, kein menschlich annotierter Sprachkorpus. Erfasst:
erhaltene Aktivität, komplett verlorene Äußerungen, akzeptierte Störabschnitte,
Segmentzahl, Initialisierung und Laufzeit. Keine Ableitung der ASR-Qualität aus
VAD-Werten. Ausgewählte leise/verrauschte/pausierte Fälle werden zusätzlich mit
den jeweils tatsächlich behaltenen Segmenten an dieselbe Whisper-Instanz gegeben.

## Entscheidung vorab

Ein Defaultwechsel braucht menschliche Mikrofonaufnahmen beider vorgesehenen
Geräte. TTS allein reicht nicht. Für eine optionale Integration: keine zusätzlichen
bedeutungsrelevanten Zahlen-/Negations-/Versionsfehler, keine verlorenen Wörter
oder Sprachsegmente, reproduzierbarer Latenz-/Störunterdrückungsgewinn und ein
Rückfall für das bestehende macOS 13. Einzelne kritische Gegenbeispiele haben
Vorrang vor einem guten Mittelwert. Fehlende Geräte-/Mikrofonläufe werden offen
geführt; negative Befunde dürfen einen Kandidaten für die Produktübernahme
ablehnen. Kein Erweitern der gesprochenen Befehle wegen ASR-Fehlern.
