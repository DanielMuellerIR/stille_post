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

    public init(config: Config.Vad) {
        // Config.save/load validieren bereits. Diese zusätzliche Normalisierung
        // schützt Aufrufer, die Config.Vad direkt konstruieren (und verhindert
        // insbesondere negative/überlaufende Array.suffix-Werte).
        self.config = config.runtimeSafe
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
        // Auch den unvollständigen letzten Frame noch mitnehmen.
        if !pendingFrame.isEmpty {
            buffer.append(contentsOf: pendingFrame)
            pendingFrame = []
        }
        guard !buffer.isEmpty else { return }
        closeSegment(reason: .flush)
    }
}
