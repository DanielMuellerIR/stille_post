import Foundation

/// Stille-Erkennung (VAD) + Segmentierung des Audio-Stroms an Sprechpausen.
///
/// Kernidee für die Geschwindigkeit der App: Wir warten NICHT bis zum Ende des
/// Diktats, sondern schneiden den Audio-Strom live an Sprechpausen in Segmente.
/// Jedes fertige Segment wird sofort transkribiert und bereinigt, während die
/// Aufnahme weiterläuft. Beim Stopp bleibt nur noch das letzte Segment übrig —
/// die Wartezeit ist damit fast konstant kurz, egal wie lange man geredet hat.
///
/// Die Erkennung ist bewusst einfach (Lautstärke-Schwelle statt neuronalem VAD):
/// Ein Frame (30 ms) gilt als Sprache, wenn sein RMS-Pegel über der Schwelle liegt.
/// Das reicht, um Pausen zu finden und reine Stille zu verwerfen (gegen die
/// Whisper-Halluzinationen bei Stille, die OpenWhispr plagen).
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
    /// Aktueller Pegel in dBFS (für die Live-Anzeige im Overlay). Thread-sicher
    /// als einfacher Snapshot-Wert.
    public private(set) var currentLevelDb: Double = -120

    private let config: Config.Vad
    /// Frame-Größe für die Pegelmessung: 30 ms bei 16 kHz = 480 Samples.
    private let frameSize = WavCodec.sampleRate * 30 / 1000

    // Zustand des laufenden Segments:
    private var buffer: [Float] = []          // Samples des aktuellen Segments
    private var pendingFrame: [Float] = []    // noch unvollständiger 30-ms-Frame
    private var segmentHadSpeech = false      // gab es in diesem Segment schon Sprache?
    private var silenceRunSec: Double = 0     // aktuelle Stille-Dauer am Stück (im Segment)
    private var totalSilenceRunSec: Double = 0 // Stille am Stück über Segmentgrenzen hinweg (Abwesenheit)
    private var autoStopFired = false
    /// Ringpuffer der letzten Samples für den Vorlauf ("Padding") des nächsten Segments,
    /// damit Wortanfänge nicht abgeschnitten werden.
    private var preRoll: [Float] = []

    public init(config: Config.Vad) {
        self.config = config
    }

    /// Nimmt neue Samples vom Aufnahme-Gerät entgegen (16 kHz mono Float).
    public func process(_ samples: [Float]) {
        // Samples in ganze 30-ms-Frames zerlegen; Rest bis zum nächsten Aufruf aufheben.
        pendingFrame.append(contentsOf: samples)
        while pendingFrame.count >= frameSize {
            let frame = Array(pendingFrame.prefix(frameSize))
            pendingFrame.removeFirst(frameSize)
            processFrame(frame)
        }
    }

    private func processFrame(_ frame: [Float]) {
        // RMS-Pegel des Frames berechnen und in dBFS umrechnen.
        var sumSquares: Double = 0
        for sample in frame { sumSquares += Double(sample) * Double(sample) }
        let rms = (sumSquares / Double(frame.count)).squareRoot()
        let db = rms > 0 ? 20 * log10(rms) : -120
        currentLevelDb = db

        let frameSec = Double(frame.count) / Double(WavCodec.sampleRate)
        let isSpeech = db > config.silenceThresholdDb

        buffer.append(contentsOf: frame)

        if isSpeech {
            segmentHadSpeech = true
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
        // Nachlauf-Polsterung: Die Stille am Ende ist ohnehin im Puffer enthalten;
        // wir kürzen sie auf `paddingSec`, damit Whisper nicht unnötig Stille bekommt.
        var samples = buffer
        let paddingSamples = Int(config.paddingSec * Double(WavCodec.sampleRate))
        let silenceSamples = Int(silenceRunSec * Double(WavCodec.sampleRate))
        if reason == .pause, silenceSamples > paddingSamples {
            samples.removeLast(min(samples.count, silenceSamples - paddingSamples))
        }
        // Vorlauf-Polsterung aus dem Ringpuffer des vorigen Segments davorsetzen.
        let segment = Segment(samples: preRoll + samples, hadSpeech: segmentHadSpeech, reason: reason)

        // Ringpuffer für das nächste Segment füllen: die letzten `paddingSec` des alten.
        preRoll = Array(buffer.suffix(paddingSamples))

        // Zustand fürs nächste Segment zurücksetzen (totalSilenceRunSec läuft weiter,
        // denn Abwesenheit erstreckt sich über Segmentgrenzen hinweg).
        buffer = []
        segmentHadSpeech = false
        silenceRunSec = 0

        onSegment?(segment)
    }

    /// Aufnahme-Ende: Das angefangene Segment abschließen und ausliefern.
    public func flush() {
        // Auch den unvollständigen letzten Frame noch mitnehmen.
        if !pendingFrame.isEmpty {
            buffer.append(contentsOf: pendingFrame)
            pendingFrame = []
        }
        guard !buffer.isEmpty else { return }
        closeSegment(reason: .flush)
    }
}
