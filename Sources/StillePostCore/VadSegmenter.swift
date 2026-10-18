import Foundation

/// Stille-Erkennung (VAD) + Segmentierung des Audio-Stroms an Sprechpausen.
///
/// Kernidee für die Geschwindigkeit der App: Wir warten NICHT bis zum Ende des
/// Diktats, sondern schneiden den Audio-Strom live an Sprechpausen in Segmente.
/// Jedes fertige Segment wird sofort lokal transkribiert, während die Aufnahme
/// weiterläuft. Die Bereinigung erfolgt einmal über den vollständigen Text.
/// Beim Stopp bleibt meist nur noch das letzte Segment übrig —
/// die Wartezeit ist damit fast konstant kurz, egal wie lange man geredet hat.
///
/// Standard ist die RMS-Pegelschwelle in 30-ms-Frames. Optional klassifiziert
/// Silero 256-ms-Fenster; Segmentierung und Stillekürzung bleiben gemeinsam.
/// Ein Modellfehler schaltet für diese Aufnahmephase dauerhaft auf RMS zurück.
public final class VadSegmenter {

    /// Ein abgeschlossenes Audio-Segment.
    public struct Segment {
        /// Die Samples (16 kHz mono Float) inklusive Vor-/Nachlauf-Polsterung.
        public let samples: [Float]
        /// Enthielt das Segment überhaupt Sprache? Reine Stille-Segmente werden
        /// vom Aufrufer verworfen statt transkribiert (Anti-Halluzination).
        public let hadSpeech: Bool
        /// Warum wurde das Segment geschlossen? (Pause, Maximallänge oder Aufnahme-Ende)
        public let reason: CloseReason
    }

    public enum CloseReason { case pause, maxLength, flush }

    /// Callback: Ein Segment ist fertig (wird auf dem Audio-Thread aufgerufen!).
    public var onSegment: ((Segment) -> Void)?
    /// Callback: Abwesenheitserkennung hat zugeschlagen (so lange Stille, dass die
    /// Aufnahme beendet werden soll). Wird höchstens einmal pro Aufnahme gefeuert.
    public var onAutoStop: (() -> Void)?
    /// Aktueller Pegel in dBFS (für die Live-Anzeige im Overlay). Der Audio-Thread
    /// schreibt, der Main-Thread liest; ein Lock bildet die nötige Speichergrenze.
    public var currentLevelDb: Double { levelLock.withLock { levelDbSnapshot } }
    private let levelLock = NSLock()
    private var levelDbSnapshot: Double = -120

    private let config: Config.Vad
    /// Frame-Größe für die Pegelmessung: 30 ms bei 16 kHz = 480 Samples.
    private let meterFrameSize = WavCodec.sampleRate * 30 / 1000
    private var meterPending: [Float] = []
    private var detector: (any SpeechActivityDetector)?
    private var frameSize: Int { detector?.frameSize ?? meterFrameSize }
    public private(set) var fallbackReason: String?
    public var onFallback: ((String) -> Void)?

    // Zustand des laufenden Segments:
    private var buffer: [Float] = []          // Samples des aktuellen Segments
    private var pendingFrame: [Float] = []    // noch unvollständiger 30-ms-Frame
    private var speechSec: Double = 0         // aufsummierte Sprache im Segment
    private var silenceRunSec: Double = 0     // aktuelle Stille-Dauer am Stück (im Segment)
    /// Stille vom Segmentanfang bis zum ersten Wort — wird beim Schließen gekürzt,
    /// damit Whisper auch am Anfang keine Stille zum Halluzinieren bekommt.
    private var leadingSilenceSec: Double = 0

    /// Enthält das Segment genug Sprache, um es überhaupt an Whisper zu geben?
    ///
    /// Bewusst eine gemessene Menge statt eines Flags: Früher setzte EIN einzelnes
    /// Frame über der Pegelgrenze dieses Flag dauerhaft. Ein Tastenklick beim
    /// Stoppen der Aufnahme genügte damit, ein ansonsten stilles Segment an Whisper
    /// zu schicken — und auf Stille erfindet Whisper "Vielen Dank.".
    private var segmentHadSpeech: Bool { speechSec >= config.minSpeechSec }
    private var totalSilenceRunSec: Double = 0 // Stille am Stück über Segmentgrenzen hinweg (Abwesenheit)
    private var autoStopFired = false
    /// Ringpuffer der letzten Samples für den Vorlauf ("Padding") des nächsten Segments,
    /// damit Wortanfänge nicht abgeschnitten werden.
    private var preRoll: [Float] = []

    public convenience init(config: Config.Vad) {
        self.init(config: config, detector: nil, fallbackReason: config.detector == .silero
            ? L10n.text("vad.fallback.unprepared") : nil)
    }

    init(config: Config.Vad, detector: (any SpeechActivityDetector)?, fallbackReason: String? = nil) {
        // Config.save/load validieren bereits. Diese zusätzliche Normalisierung
        // schützt Aufrufer, die Config.Vad direkt konstruieren (und verhindert
        // insbesondere negative/überlaufende Array.suffix-Werte).
        self.config = config.runtimeSafe
        self.detector = detector
        self.fallbackReason = fallbackReason
    }

    /// Nimmt neue Samples vom Aufnahme-Gerät entgegen (16 kHz mono Float).
    public func process(_ samples: [Float]) {
        // Die Pegelanzeige bleibt unabhängig vom gewählten Detektor bei 30 ms.
        meterPending.append(contentsOf: samples)
        while meterPending.count >= meterFrameSize {
            let frame = Array(meterPending.prefix(meterFrameSize))
            meterPending.removeFirst(meterFrameSize)
            levelLock.withLock { levelDbSnapshot = Self.levelDb(frame) }
        }
        pendingFrame.append(contentsOf: samples)
        drainFrames()
    }

    private func drainFrames() {
        while pendingFrame.count >= frameSize {
            let frame = Array(pendingFrame.prefix(frameSize))
            pendingFrame.removeFirst(frameSize)
            classify(frame)
        }
    }

    private static func levelDb(_ frame: [Float]) -> Double {
        let sum = frame.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (sum / Double(frame.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }

    private func classify(_ frame: [Float]) {
        let isSpeech: Bool
        if let detector {
            do { isSpeech = try detector.isSpeech(frame) }
            catch {
                // Das fehlgeschlagene Fenster ist noch unverarbeitet. Erneut in
                // RMS-Frames einreihen, damit weder Samples verloren gehen noch
                // ein einzelner Klick plötzlich als 256 ms Sprache zählt.
                self.detector = nil
                let reason = L10n.text("vad.fallback.inference")
                fallbackReason = reason
                onFallback?(reason)
                pendingFrame.insert(contentsOf: frame, at: 0)
                return
            }
        } else { isSpeech = Self.levelDb(frame) > config.silenceThresholdDb }
        processFrame(frame, isSpeech: isSpeech)
    }

    private func processFrame(_ frame: [Float], isSpeech: Bool) {
        let frameSec = Double(frame.count) / Double(WavCodec.sampleRate)

        buffer.append(contentsOf: frame)

        if isSpeech {
            // Erster hörbarer Frame im Segment: Die bis hierhin gelaufene Stille ist
            // der Vorlauf. Bewusst schon beim ersten Frame (nicht erst ab
            // `minSpeechSec`) — sonst schnitte der Vorlauf-Trim Wortanfänge ab.
            if speechSec == 0 { leadingSilenceSec = silenceRunSec }
            speechSec += frameSec
            silenceRunSec = 0
            totalSilenceRunSec = 0
        } else {
            silenceRunSec += frameSec
            totalSilenceRunSec += frameSec
            // Abwesenheitserkennung: sehr lange gar keine Sprache -> Aufnahme stoppen lassen.
            if config.autoStopAfterSilenceSec > 0,
               totalSilenceRunSec >= config.autoStopAfterSilenceSec,
               !autoStopFired {
                autoStopFired = true
                onAutoStop?()
            }
        }

        let segmentSec = Double(buffer.count) / Double(WavCodec.sampleRate)

        // Segment an einer Sprechpause schließen — aber nur, wenn schon Sprache drin ist
        // und es die Mindestlänge erreicht hat (sonst weiterführen).
        if segmentHadSpeech, silenceRunSec >= config.splitAfterSilenceSec, segmentSec >= config.minSegmentSec {
            closeSegment(reason: .pause)
        } else if segmentSec >= config.maxSegmentSec {
            // Hard-Limit erreicht (jemand redet ohne Pause — oder reine Stille,
            // die wir nicht endlos puffern wollen) -> trotzdem schneiden.
            closeSegment(reason: .maxLength)
        }
    }

    private func closeSegment(reason: CloseReason) {
        // Stille kürzen — der wichtigste Schutz gegen Whisper-Halluzinationen:
        // Auf reiner Stille erfindet Whisper Floskeln ("Vielen Dank."), und zwar
        // mit voller Konfidenz (no_speech_prob ~3e-08) — eine Schwelle im Client
        // kann das nicht abfangen. Was Whisper nie sieht, kann es nicht erfinden.
        // Darum bekommt es je Segmentrand höchstens `paddingSec` Stille.
        //
        // Das gilt bei JEDEM Schließgrund. Früher wurde nur `.pause` gekürzt; bei
        // `.flush` (Aufnahme-Ende) und `.maxLength` ging die Stille ungekürzt an
        // Whisper. Real reproduziert: "Okay" + 30 s Stille -> " Okay. Vielen Dank."
        var samples = buffer
        let paddingSamples = Int(config.paddingSec * Double(WavCodec.sampleRate))

        // Nachlauf: die Stille am Ende steht schon im Puffer, wir stutzen sie.
        let trailingSilenceSamples = Int(silenceRunSec * Double(WavCodec.sampleRate))
        if trailingSilenceSamples > paddingSamples {
            samples.removeLast(min(samples.count, trailingSilenceSamples - paddingSamples))
        }
        // Vorlauf: Stille zwischen Segmentanfang und erstem Wort (z. B. Aufnahmestart
        // bis man zu sprechen beginnt). Nur sinnvoll, wenn überhaupt Sprache kam —
        // sonst ist `leadingSilenceSec` bedeutungslos und der Nachlauf-Trim hat das
        // sprachlose Segment ohnehin schon auf Polstergröße gestutzt.
        if segmentHadSpeech {
            let leadingSilenceSamples = Int(leadingSilenceSec * Double(WavCodec.sampleRate))
            if leadingSilenceSamples > paddingSamples {
                samples.removeFirst(min(samples.count, leadingSilenceSamples - paddingSamples))
            }
        }
        // Vorlauf-Polsterung aus dem Ringpuffer des vorigen Segments davorsetzen.
        let segment = Segment(samples: preRoll + samples, hadSpeech: segmentHadSpeech, reason: reason)

        // Ringpuffer für das nächste Segment füllen: die letzten `paddingSec` des alten.
        preRoll = Array(buffer.suffix(paddingSamples))

        // Zustand fürs nächste Segment zurücksetzen (totalSilenceRunSec läuft weiter,
        // denn Abwesenheit erstreckt sich über Segmentgrenzen hinweg).
        buffer = []
        speechSec = 0
        silenceRunSec = 0
        leadingSilenceSec = 0

        onSegment?(segment)
    }

    /// Aufnahme-Ende: Das angefangene Segment abschließen und ausliefern.
    public func flush() {
        drainFrames()
        if !pendingFrame.isEmpty {
            let tail = pendingFrame
            pendingFrame = []
            if detector != nil {
                // Nur die Inferenz polstert auf 256 ms; die Segmentdauer und WAV
                // enthalten ausschließlich tatsächlich empfangene Samples.
                classify(tail)
                drainFrames()
            } else { buffer.append(contentsOf: tail) }
            if !pendingFrame.isEmpty {
                buffer.append(contentsOf: pendingFrame)
                pendingFrame = []
            }
        }
        guard !buffer.isEmpty else { return }
        closeSegment(reason: .flush)
    }
}
