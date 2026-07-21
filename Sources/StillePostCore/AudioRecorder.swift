import Foundation
import AVFoundation

/// Nimmt Audio vom konfigurierten Mikrofon auf und liefert 16-kHz-mono-Float-Samples.
///
/// Wichtig (gelernt aus dem Hammerspoon-Prototyp): KEIN fest verdrahteter Mikrofon-
/// Index! Ohne konkrete Auswahl nutzt `AVAudioEngine.inputNode` automatisch das im
/// System eingestellte Standard-Eingabegerät. Eine ausdrückliche Auswahl wird über
/// die stabile CoreAudio-UID verbunden, nie über eine flüchtige Gerätenummer.
///
/// Das Roh-Audio des Geräts (z. B. 48 kHz) wird live per AVAudioConverter auf
/// 16 kHz mono heruntergerechnet — das Format, das Whisper erwartet.
public final class AudioRecorder {

    /// Callback mit neuen Samples (16 kHz mono). Läuft auf dem Audio-Thread!
    public var onSamples: (([Float]) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let config: Config.Audio

    public init(config: Config.Audio = Config.Audio()) {
        self.config = config
    }

    /// Fragt die Mikrofon-Berechtigung ab (macOS zeigt beim ersten Mal den System-Dialog).
    public static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Startet die Aufnahme. Wirft, wenn das Audio-System nicht startet
    /// (z. B. kein Eingabegerät vorhanden).
    public func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try AudioInputDeviceCatalog.apply(uid: config.inputDeviceUID, to: input)
        } catch AudioInputDeviceCatalog.SelectionError.unavailable {
            throw RecorderError.inputDeviceUnavailable(selectedDeviceName)
        } catch AudioInputDeviceCatalog.SelectionError.cannotConfigure(let status) {
            throw RecorderError.inputDeviceConfigurationFailed(selectedDeviceName, status)
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // Ziel-Format der Pipeline: 16 kHz, 1 Kanal, Float32.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WavCodec.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.formatSetupFailed
        }
        self.converter = converter

        // Tap: bekommt regelmäßig Puffer mit Roh-Audio vom Mikrofon.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }

            // Puffer fürs Zielformat anlegen (Größe proportional zur Rate + Reserve).
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            // Der Converter zieht sich die Eingabe über diesen Block. Wir geben genau
            // einen Puffer und melden danach "keine Daten mehr" (sonst Endlosschleife).
            var provided = false
            var conversionError: NSError?
            converter.convert(to: out, error: &conversionError) { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, out.frameLength > 0,
                  let channel = out.floatChannelData?[0] else { return }

            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            self.onSamples?(samples)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stoppt die Aufnahme und gibt das Audio-Gerät wieder frei.
    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    public enum RecorderError: Error, LocalizedError {
        case formatSetupFailed
        case inputDeviceUnavailable(String)
        case inputDeviceConfigurationFailed(String, OSStatus)
        public var errorDescription: String? {
            switch self {
            case .formatSetupFailed: return L10n.text("core.audio.format_setup_failed")
            case .inputDeviceUnavailable(let name):
                return L10n.format("core.audio.device_unavailable", name)
            case .inputDeviceConfigurationFailed(let name, let status):
                return L10n.format("core.audio.device_configuration_failed", name, status)
            }
        }
    }

    private var selectedDeviceName: String {
        config.inputDeviceName.isEmpty ? config.inputDeviceUID : config.inputDeviceName
    }
}
