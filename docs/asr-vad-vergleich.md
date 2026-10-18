# Vergleich lokaler Spracherkennung und Sprachaktivität

Prüfdatum: 2026-10-18. Produktbasis: 0.9.39 / `469ceea`.
Die Untersuchung ändert keine Produktkomponente und keine Voreinstellung.

## Entscheidung

**Whisper large-v3-turbo beibehalten.** Parakeet v3 ist im Dateivergleich
schneller, verfehlt aber die vorher festgelegte Qualitätsgrenze: zusätzliche
Fachbegriffs-, Namens- und Versionsfehler. Weder ein Defaultwechsel noch eine
alternative Produktengine ist durch diese Messung gerechtfertigt.

**Silero für eine optionale Integration weiterverfolgen.** Der geprüfte Detektor
behält die künstliche leise Sprache und verwirft das reine Rauschen, während
der bisherige Pegeldetektor diese Fälle verwechselt. Das erlaubt eine begrenzte
Integration mit Rückfall und anschließender Mikrofonabnahme. Es erlaubt keinen
allgemeinen Qualitätsanspruch und keine sofortige Defaultumstellung.

## Kandidaten und Primärquellen

Alle Quellen wurden am Prüfdatum gelesen; Modellrevisionen und Einzeldatei-Hashes
stehen in [models.json](benchmarks/asr-vad/models.json).

| Komponente | Geprüfter Stand | Lizenz | Umfang / Plattform |
|---|---|---|---|
| Whisper | whisper.cpp 1.9.5, large-v3-turbo | MIT | Vorhandenes Modell: 1.624.555.275 Byte; bestehender Produktweg ab macOS 13 |
| Parakeet | NVIDIA TDT 0.6B v3, CoreML-Konvertierung `7dd20fe6` | CC BY 4.0 | Ausgewählte Encoder-/Decoder-/Joint-/Preprocessor-/Vokabulardateien: 483.105.645 Byte; 0,6 Milliarden Parameter |
| FluidAudio | 0.17.7, Commit `503b4bd1` | Apache 2.0 | SDK verlangt macOS 14 / iOS 17 und Swift 6.0; Vergleich verwendet Swift 6.2-Pakettraits ohne NeMo-Normalisierung |
| Silero | CoreML 6.2.1, Revision `b419383c` | MIT | 1.063.425 Byte; 16 kHz, 4.096 neue Samples + 64 Kontextsamples, 256-ms-Schritte |

Die Plattformangabe des SDK folgt seinem
[versionierten Package](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/Package.swift),
die SDK-Lizenz der [Lizenzdatei](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/LICENSE).
DE/EN und Modelllizenz sind in der
[NVIDIA-Modellkarte](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) beschrieben;
die ausgewählten Dateien stammen aus der
[festen CoreML-Revision](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/tree/7dd20fe6b1797d35f5e3307e8b1732d9a178edfe).
Die ursprünglichen NVIDIA-Gewichte sind separat rund 2,51 GB groß und wurden
für diesen Vergleich nicht geladen.

Silero upstream ist bereits
[6.2.3](https://github.com/snakers4/silero-vad/releases/tag/v6.2.3);
gemessen wurde ausdrücklich das vom SDK verwendete
[CoreML-Modell 6.2.1](https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96).
Upstream-/Python-Paketversion und CoreML-Konvertierung sind unterschiedliche
Stände. Die MIT-Lizenzen von
[Silero](https://github.com/snakers4/silero-vad/blob/v6.2.3/LICENSE) und
[whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/LICENSE)
sind separat berücksichtigt. Eine spätere Auslieferung muss deren Hinweise
und die Attribution des Parakeet-Modells erhalten.
Auch das [Whisper-Modell](https://huggingface.co/openai/whisper-large-v3-turbo?library=transformers)
ist unter MIT veröffentlicht.

## Verfahren

Vor Messbeginn wurden [Protokoll](benchmarks/asr-vad/PROTOCOL.md),
[Referenzkorpus](benchmarks/asr-vad/corpus.json) und Übernahmekriterien festgelegt.
24 künstliche Sprachdateien, je zwölf DE/EN, plus Stille/Rauschen/Klicks;
insgesamt 274,969 s. Die längeren Dateien dauern 63,795 s DE und 57,146 s EN.
Lokale Stimmen Anna/Samantha, PCM16 mono 16 kHz. Dieselben WAV-Hashes und
Whisper-/CoreML-Modelle wurden auf beiden Geräten geprüft.

ASR: feste 15-s-Segmente ohne VAD, keine Bereinigung, Temperatur 0, feste
Whisper-Sprache DE/EN, Parakeet-Automatik. Drei neue Prozesse für Kaltstart,
danach separates Priming und drei warme Korpusdurchgänge. Die ausgegebenen
Segmente werden in Reihenfolge verbunden. VAD: tatsächlicher Produktdetektor
aus einer gehashten Quellkopie, separat vom Silero-Detektor mit den dokumentierten
Grenzwerten. Zusätzliche Whisper-Proben verwenden tatsächlich behaltene
VAD-Segmente der leisen, verrauschten und pausierten Dateien.

Eine Zusatzprobe gleicht die äußere Kaltstart-Messgrenze an: Elternprozessstart
bis vollständig vorliegende erste Antwort, jeweils drei neue Prozesse mit
bereits warmen OS-/Modell-Caches. Ursprüngliche interne Initialisierungswerte
bleiben separat erhalten; sie sind nicht dieselbe Messgröße.

Der kleine SDK-/Silero-Gerätetest lief vor der größeren Parakeet-Beschaffung.
Swift-Inferenz bestand auch mit gesperrtem Netzwerkzugriff. Der Whisper-Adapter
startet eigene Loopback-Prozesse; bestehende Dienste werden nicht neu gestartet.
Anleitung: [begrenzter Vergleichsadapter](benchmarks/asr-vad/README.md).

## Messwerte

Die vollständigen neutralen Kennzahlen stehen in
[results.json](benchmarks/asr-vad/results.json). Tabellen und Bewertung folgen
den dort gespeicherten tatsächlich ausgeführten Läufen.

| Gerät | ASR | WER DE | WER EN | Warme Gesamtlaufzeit | Median je Sprachdatei |
|---|---|---:|---:|---:|---:|
| Apple M5 Max (128 GiB) | whisper | 15,15% | 19,49% | 17,584 s | 0,141 s |
| Apple M5 Max (128 GiB) | parakeet | 18,56% | 20,94% | 6,802 s | 0,040 s |
| Apple M1 (16 GiB) | whisper | 15,15% | 19,49% | 208,347 s | 1,806 s |
| Apple M1 (16 GiB) | parakeet | 18,94% | 20,94% | 12,181 s | 0,072 s |

Gesamtlaufzeit: drei vollständige Durchgänge einschließlich Stördateien. WER-Nenner:
je Gerät/Engine 792 DE- und 831 EN-Referenzwörter über drei Durchgänge. Keine
leeren ASR-Sprachsegmente. Jede der 27 Dateien liefert innerhalb eines Geräts
und einer Engine in allen drei Wiederholungen denselben Text. Die Unterschiede
zwischen Geräten bleiben in den Rohbelegen erhalten.

| Gerät | ASR | Prozessstart bis erster Antwort, drei Proben | Beobachtetes Prozess-RSS |
|---|---|---|---:|
| Apple M5 Max | whisper | 0,794, 0,884, 0,752 s | 1868,9 MiB |
| Apple M5 Max | parakeet | 0,205, 0,199, 0,196 s | 104,3 MiB |
| Apple M1 | whisper | 2,463, 2,372, 2,421 s | 1856,3 MiB |
| Apple M1 | parakeet | 0,300, 0,229, 0,243 s | 82,7 MiB |

Kaltstart-Zusatzprobe mit bereits warmen OS-/Modell-Caches und gleicher äußerer
Messgrenze, Auflösung etwa 5 ms beim Swift-Ergebnis. Das RSS ist beim Whisper-
Prozess eine gesampelte Untergrenze, beim CoreML-Prozess eine Prozessspitze;
beide lassen Speicher anderer Systemprozesse und Beschleuniger aus. Daraus
folgt kein entsprechender Gewinn beim gesamten RAM-Verbrauch.

| Gerät | VAD | Komplett verlorene Sprachdateien | Akzeptierte Stördateien | Warme Gesamtlaufzeit |
|---|---|---|---|---:|
| Apple M5 Max | rms | de-quiet, en-quiet | noise | 0,278 s |
| Apple M5 Max | silero | keine | keine | 0,876 s |
| Apple M1 | rms | de-quiet, en-quiet | noise | 0,375 s |
| Apple M1 | silero | keine | keine | 0,872 s |

Silero behält auf beiden Geräten 100 % der markierten künstlichen Aktivität;
RMS behält außerhalb der beiden leisen Dateien ebenfalls 100 %. Die Pausenfälle
ergeben RMS acht, Silero sieben Segmente: zwei Äußerungen sind zusammengefasst,
keine markierte Sprache geht verloren. Separate Whisper-Nachproben bestätigen
die leisen Silero-Ausgaben einschließlich Negation und Zahlwert; RMS liefert
dafür keinen Text. Stille und Klicks verwirft bereits der bestehende VAD.

Der erste ursprüngliche Parakeet-Lauf benötigte innerhalb des Messprozesses
auf dem M5 13,211 s, auf dem M1 28,502 s.
Die späteren schnellen Prozessstarts ersetzen diesen beobachteten
Initialisierungs-/CoreML-Cacheeffekt nicht. Vollständige initiale und äußere
Kaltwerte, CER, Wortkorrekturen und VAD-Speicher stehen in results.json.

## Erforderliche Korrekturen und Fehlergrenzen

WER/CER und minimale Wortkorrekturen sind mechanische Levenshtein-Maße.
Ziffern statt Zahlwörtern zählen darin als Änderungen, auch wenn der Wert stimmt.
Die Werte messen weder menschliche Bearbeitungszeit noch ausschließlich
bedeutungsrelevante Fehler. Die folgenden Korrekturen wurden anhand der
festgelegten Referenzen gesondert gelesen:

- DE-Name: Parakeet macht aus Maja Kern im kurzen Namensfall „Maria Kern“;
  Whisper trifft den Namen. Eine erforderliche Namenskorrektur.
- EN-Fachbegriff: Parakeet schreibt im kurzen Fachbegriffsfall „PostGur SQL“
  statt PostgreSQL. Eine manuelle Ersetzung der Wortgruppe; mechanisch zwei
  Wortoperationen. Whisper trifft den Begriff.
- DE-Langfall: Parakeet liefert dreimal `0.9.939` statt `0.9.39`; drei
  erforderliche Wertkorrekturen. Whisper trifft diese drei Versionen.
- DE-Pausenfall: Beide irren bei der Version: Whisper `0.9.99`, Parakeet
  `0.9.909` statt `0.9.39`. Der bestehende Weg hat ebenfalls Grenzen.
- Lange EN-Passagen haben bei beiden Erkennungsfehler, darunter beschädigte
  Satzteile um „must not start“. Harte Schnittgrenzen sind ein Stressfall;
  daraus folgt keine Aussage über natürliche VAD-Grenzen oder bessere
  menschliche Diktate.
- DE-Formatbefehle werden bei beiden teilweise zusammengezogen. Das verbessert
  die sichere Raw-Befehlserkennung nicht. Vollständige Befehlsformen bleiben
  erforderlich; es wurden keine neuen Synonyme eingeführt. Bereits dokumentierte
  end/and-Grenzen und der sichere englische Markerrückfall bleiben gültig.

Alle Sprachdateien lieferten bei beiden ASR-Engines nicht leere Segmente.
Anfang, Mitte und Ende der langen Passagen sind vorhanden; die genannten
Wort-/Wertfehler bleiben trotzdem Korrekturbedarf. Reine Stördateien werden
separat bewertet: ihre Halluzinationen fließen nicht in eine WER mit leerer
Referenz ein.

## Grenzen und nächste Umsetzung

Es liegen **keine menschlichen Mikrofonaufnahmen** vor. Die künstliche
Aktivitätsmaske basiert auf sauberer TTS-Energie in 30-ms-Frames. Vollständige
Retention dieser Maske beweist keine perfekte Erkennung menschlicher Sprache.
Die Schwelle −52 dBFS ist ein kontrollierter Gegenfall zum Pegeldetektor bei
−45 dBFS; sie repräsentiert nicht alle leisen Stimmen oder Mikrofone.

Beide Geräte liefen unter macOS 26.7.1. macOS 13/14, Intel, iOS, Akkuverbrauch
und thermischer Dauerbetrieb wurden nicht am Gerät geprüft. Die Hostressourcen
waren geteilt; eigene Vergleiche liefen seriell. Latenzen sind beobachtete
Dateilaufwerte unter dieser Last, keine exklusiven Hardwarebenchmarks.
Prozesskaltstart erhält OS-/CoreML-Caches und ist kein Bootkaltstart.
Stopp-bis-Rohtext enthält hier weder vorgezogene Live-Transkription noch Cleanup
oder Einfügen. Prozess-RSS erfasst ANE-/Metal-/XPC-Speicher nicht vollständig.

Silero sollte als Opt-in mit intaktem bisherigen Detektor integriert werden.
Modellbeschaffung braucht feste Revision, Größen-/Hashprüfung und klaren
Fehlerrückfall. Die macOS-13-Untergrenze darf nicht durch eine direkte
FluidAudio-Abhängigkeit verloren gehen; dafür zuerst einen kleinen
Kompatibilitätsversuch machen. Eine schmale lokale CoreML-Anbindung desselben
Modells ist eine mögliche Implementierung, deren Plattformfähigkeit und
256-ms-Zustandsführung gesondert zu prüfen sind. Echte kurze/leise Wörter,
Tastenklicks, Rauschen, lange Pausen, Pause/Fortsetzen, Abbruch und genau eine
Gesamtbereinigung bleiben Integrations-Abnahmekriterien.

Parakeet ist für die Übernahme unter den gemessenen Bedingungen abgelehnt.
Ein späterer neuer Kandidat braucht einen neuen begrenzten Vergleich; die
Herstellerbenchmarks und die hier beobachtete Geschwindigkeit rechtfertigen
keine Lockerung der Qualitätsgrenzen. Die bereits offenen Mikrofon-/Geräte-
und Quit-Löschfehlerabnahmen bleiben eigenständige offene Arbeit.
