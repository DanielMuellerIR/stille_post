import AVFAudio
import Foundation
import StillePostClientCore

@MainActor final class AudioRecorder: NSObject, AudioCapture, AVAudioRecorderDelegate {
    var onProgress: ((TimeInterval) -> Void)?
    var onStopped: ((TimeInterval, ClientFailure?) -> Void)?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var interruption: NSObjectProtocol?
    private var routeChange: NSObjectProtocol?

    override init() {
        super.init()
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      type == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.interrupted() }
            }
        routeChange = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                Task { @MainActor in self?.interrupted() }
            }
    }

    func start(at url: URL, maxDuration: TimeInterval) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw ClientFailure.microphoneDenied }
        try Task.checkCancellation()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                // Die Encoderprobe lehnt 64 kbit/s bei 16 kHz mono mit '!dat' ab; 32 kbit/s funktioniert.
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            recorder.delegate = self
            guard recorder.record(forDuration: maxDuration) else { throw ClientFailure.recordingFailed }
            self.recorder = recorder
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    self.onProgress?(recorder.currentTime)
                }
            }
        } catch {
            _ = stop()
            throw error as? ClientFailure ?? ClientFailure.recordingFailed
        }
    }

    func stop() -> TimeInterval {
        let duration = recorder?.currentTime ?? 0
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        timer?.invalidate(); timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    private func interrupted() {
        guard recorder != nil else { return }
        onStopped?(stop(), .interrupted)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            let duration = max(recorder.currentTime, (try? AVAudioPlayer(contentsOf: recorder.url).duration) ?? 0)
            _ = self.stop()
            self.onStopped?(duration, flag ? nil : .recordingFailed)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.onStopped?(self.stop(), .recordingFailed)
        }
    }

    deinit {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        if let routeChange { NotificationCenter.default.removeObserver(routeChange) }
        timer?.invalidate()
    }
}
