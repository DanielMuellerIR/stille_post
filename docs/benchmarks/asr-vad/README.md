# ASR und VAD vergleichen

Isolierter Entwicklungsvergleich für Apple Silicon, macOS 14+, Swift 6.2+.
Das Produkt behält macOS 13 und seine bisherigen Komponenten. Protokoll und
Übernahmekriterien stehen in [PROTOCOL.md](PROTOCOL.md), Ergebnisse in
[../../asr-vad-vergleich.md](../../asr-vad-vergleich.md).

`compare.py build` kopiert den tatsächlichen Produktkern in das angegebene
Arbeitsverzeichnis und protokolliert dessen Hashes. Das separate Paket pinnt
FluidAudio 0.17.7; es wird nicht vom Produkt-Package geladen. Modelle werden
ausschließlich von festen Revisionen aus `models.json` geladen und für jede
Datei nach Größe und SHA-256 geprüft. SDK-/Modellbeschaffung benötigen Netzwerk;
der Messlauf benötigt keine externen Endpunkte. Swift-Inferenz läuft mit gesperrtem
Netzwerk; Whisper-Anfragen gehen ausschließlich an `127.0.0.1:18171`.

```bash
comparison_work="$HOME/Testprotokolle/stille_post/asr-vad-comparison"
python3 docs/benchmarks/asr-vad/compare.py corpus --work "$comparison_work"
python3 docs/benchmarks/asr-vad/compare.py download-silero --work "$comparison_work"
python3 docs/benchmarks/asr-vad/compare.py build --work "$comparison_work"
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  "$comparison_work/build/release/CompareAudio" gate "$comparison_work"
# Erst nach bestandenem gate.json das größere Modell laden:
python3 docs/benchmarks/asr-vad/compare.py download-parakeet --work "$comparison_work"
python3 docs/benchmarks/asr-vad/compare.py measure --work "$comparison_work" \
  --whisper-model "$HOME/Library/Application Support/StillePost/models/ggml-large-v3-turbo.bin"
# Zusatzprobe mit gleicher äußerer Messgrenze und bereits warmen OS-Caches:
python3 docs/benchmarks/asr-vad/compare.py cold --work "$comparison_work" \
  --whisper-model "$HOME/Library/Application Support/StillePost/models/ggml-large-v3-turbo.bin"
```

Benötigt den installierten `whisper-server`, `say` und `afconvert`. Port 18171
muss frei sein. Der Lauf startet und beendet ausschließlich eigene
Whisper-Prozesse; der Alltagsdienst bleibt bestehen. Für ein zweites Gerät
`audio/`, `manifest.json`, `models/`, den passenden CompareAudio-Build und diesen
Treiber kopieren. WAV-Hashes vor dem Lauf prüfen. Die beim Bau erzeugte
Core-Ressourcen-Bundlekopie neben dem Binary mitnehmen. Auf einem anderen
macOS-/Toolchainstand erneut bauen.

Ergebnisdateien liegen ausschließlich im Arbeitsverzeichnis: rohe Texte,
Segmenttexte, Zeiten, Speicher und VAD-Grenzen. `*-scored.json` enthält die
mechanische Bewertung. Bedeutungsfehler anhand der unveränderten Referenzen
gesondert prüfen; die Berechnung ersetzt diese Prüfung nicht. TTS-Ergebnisse
sind kein Nachweis menschlicher Mikrofonqualität. Fehlerläufe behalten ihre
Logs und Audioeingaben. Wiederholungen in einem neuen Arbeitsordner ausführen,
damit keine alten Ergebnisdateien als neue Belege gelten.
