import Foundation
import AVFoundation
import CoreAudio

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
    /// Laufzeitfehler werden genau einmal pro Aufnahme auf dem Hauptthread gemeldet.
    public var onFailure: ((Error) -> Void)?

    private var configurationObserver: NSObjectProtocol?
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var recordingID: UUID?
    private var failureReported = false
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
        let initialUID = config.inputDeviceUID.isEmpty
            ? AudioInputDeviceCatalog.defaultDevice()?.uid : config.inputDeviceUID
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
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.formatSetupFailed
        }

        // Ziel-Format der Pipeline: 16 kHz, 1 Kanal, Float32.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WavCodec.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.formatSetupFailed
        }
        let samplesCallback = onSamples

        // Tap: bekommt regelmäßig Puffer mit Roh-Audio vom Mikrofon.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in

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
            samplesCallback?(samples)
        }

        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
            let recordingID = UUID()
            self.recordingID = recordingID
            failureReported = false
            try observeChanges(engine: engine, recordingID: recordingID, selectedUID: initialUID)
        } catch {
            // Auch ein Startfehler nach installiertem Tap muss das Gerät freigeben.
            removeObservers()
            input.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.recordingID = nil
            throw error
        }
    }

    /// Stoppt die Aufnahme und gibt das Audio-Gerät wieder frei.
    public func stop() {
        // Eigene Stopps lösen ebenfalls Engine-Meldungen aus. Zuerst abmelden,
        // damit sie nicht als Geräteverlust der beendeten Aufnahme erscheinen.
        recordingID = nil
        removeObservers()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    deinit { stop() }

    private func observeChanges(engine: AVAudioEngine, recordingID: UUID, selectedUID: String?) throws {
        guard let selectedUID,
              let deviceID = AudioInputDeviceCatalog.deviceID(forUID: selectedUID) else {
            throw RecorderError.inputDeviceUnavailable(selectedDeviceName)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.reportFailure(recordingID: recordingID)
        }

        let system = AudioObjectID(kAudioObjectSystemObject)
        let watch: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (system, kAudioHardwarePropertyDevices),
            (system, kAudioHardwarePropertyDefaultInputDevice),
            (deviceID, kAudioDevicePropertyDeviceIsAlive)
        ]
        for (object, selector) in watch {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.recordingID == recordingID else { return }
                // Ein Wechsel des Standards betrifft nur „Systemstandard“.
                // Eine explizite Auswahl bleibt bei Änderungen anderer Geräte aktiv.
                let disappeared = AudioInputDeviceCatalog.deviceID(forUID: selectedUID) == nil
                    || !AudioInputDeviceCatalog.isAlive(deviceID)
                let defaultChanged = self.config.inputDeviceUID.isEmpty
                    && AudioInputDeviceCatalog.defaultDevice()?.uid != selectedUID
                if disappeared || defaultChanged { self.reportFailure(recordingID: recordingID) }
            }
            let status = AudioObjectAddPropertyListenerBlock(object, &address, .main, listener)
            guard status == noErr else {
                throw RecorderError.inputDeviceConfigurationFailed(selectedDeviceName, status)
            }
            deviceListeners.append((object, address, listener))
        }
        if !AudioInputDeviceCatalog.isAlive(deviceID)
            || (config.inputDeviceUID.isEmpty && AudioInputDeviceCatalog.defaultDevice()?.uid != selectedUID) {
            // Der Standard kann schon während des Starts wechseln. Die Meldung
            // wartet bis zum nächsten Main-Thread-Schritt, wenn .recording gesetzt ist.
            DispatchQueue.main.async { [weak self] in self?.reportFailure(recordingID: recordingID) }
        }
    }

    private func reportFailure(recordingID: UUID) {
        guard self.recordingID == recordingID, !failureReported else { return }
        failureReported = true
        onFailure?(RecorderError.recordingInterrupted)
    }

    private func removeObservers() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        for (object, storedAddress, listener) in deviceListeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        deviceListeners.removeAll()
    }

    public enum RecorderError: Error, LocalizedError {
        case recordingInterrupted
        case formatSetupFailed
        case inputDeviceUnavailable(String)
        case inputDeviceConfigurationFailed(String, OSStatus)
        public var errorDescription: String? {
            switch self {
            case .recordingInterrupted: return L10n.text("core.audio.recording_interrupted")
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
