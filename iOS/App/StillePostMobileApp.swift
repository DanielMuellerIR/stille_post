import SwiftUI
import StillePostClientCore

@main struct StillePostMobileApp: App {
    @StateObject private var model: MobileModel
    @StateObject private var localModels = LocalModelController()

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingRecording", isDirectory: true)
        let capture: any AudioCapture
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["STILLEPOST_MOBILE_SYNTHETIC_CAPTURE"] == "1" {
            capture = SimulatorAudioCapture()
        } else { capture = AudioRecorder() }
        #else
        capture = AudioRecorder()
        #endif
        _model = StateObject(wrappedValue: MobileModel(capture: capture, files: PendingRecordingFiles(directory: directory)))
    }

    var body: some Scene {
        WindowGroup {
            DictationView(model: model, localModels: localModels)
                .tint(.indigo)
                .task { await model.load() }
                // Vor dem Hintergrundwechsel stoppen: Die Audio-Session kann sonst
                // weiterlaufen, bevor SwiftUI den neuen Szenenzustand meldet.
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                    if model.state.phase == .recording { model.interrupt() }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in
                    model.interrupt()
                    localModels.interrupt(.background)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    localModels.interrupt(.memory)
                }
        }
    }
}
