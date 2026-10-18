import AppKit
import SwiftUI
import StillePostCore

final class TestDictationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: TestDictationViewModel
    private let closingError: (String) -> Void
    private var observers: [NSObjectProtocol] = []
    var isActive: Bool { model.session?.isActive == true }
    init(engine: @escaping () -> DictationEngine?, configuration: @escaping () -> Config,
         nextConfiguration: @escaping () -> Config, canStart: @escaping () -> Bool,
         onSettings: @escaping (DiagnosticFinding.Action) -> Void, onClosingError: @escaping (String) -> Void,
         context: @escaping (Config) -> DiagnosticContext = { AppDiagnosticContext.capture(configuration: $0) },
         onBegin: @escaping () -> Bool = { true }) {
        model = TestDictationViewModel(engine: engine, configuration: configuration,
            nextConfiguration: nextConfiguration, canStart: canStart, onSettings: onSettings, context: context, onBegin: onBegin)
        closingError = onClosingError
        super.init()
        observers = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if self?.isActive == true { self?.model.cancel() }
            }
        }
    }
    deinit { for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) } }
    func owns(_ engine: DictationEngine) -> Bool { model.session?.owns(engine) == true }
    func receiveState(_ state: DictationState) { model.session?.receiveState(state) }
    func receiveResult(_ result: DictationResult) { model.session?.receiveResult(result) }
    func cancel() { model.cancel() }
    @discardableResult func releaseForRegularStart() -> Bool { model.session?.releaseForRegularStart() ?? true }
    func show() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 680),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            value.title = L10n.text("test_dictation.title")
            value.contentMinSize = NSSize(width: 620, height: 580)
            value.isReleasedWhenClosed = false; value.delegate = self
            value.contentView = NSHostingView(rootView: TestDictationView(model: model))
            value.center(); window = value
        }
        model.open()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        if let error = model.close() { closingError(error) }
    }
    func prepareForTermination() { _ = model.close(); window?.orderOut(nil) }
}

final class TestDictationViewModel: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var reviewed: Config?
    @Published private(set) var context = DiagnosticContext()
    @Published private(set) var allowed = false
    @Published private(set) var note: String?
    private(set) var session: TestDictationSession?
    let onSettings: (DiagnosticFinding.Action) -> Void
    private let engineProvider: () -> DictationEngine?
    private let configurationProvider: () -> Config
    private let nextConfiguration: () -> Config
    private let canStart: () -> Bool
    private let contextProvider: (Config) -> DiagnosticContext
    private let onBegin: () -> Bool
    private var availabilityTimer: Timer?
    private var wasActive = false

    init(engine: @escaping () -> DictationEngine?, configuration: @escaping () -> Config,
         nextConfiguration: @escaping () -> Config, canStart: @escaping () -> Bool,
         onSettings: @escaping (DiagnosticFinding.Action) -> Void,
         context: @escaping (Config) -> DiagnosticContext = { AppDiagnosticContext.capture(configuration: $0) },
         onBegin: @escaping () -> Bool = { true }) {
        engineProvider = engine; configurationProvider = configuration; self.nextConfiguration = nextConfiguration
        self.canStart = canStart; self.onSettings = onSettings; contextProvider = context
        self.onBegin = onBegin
    }
    deinit { availabilityTimer?.invalidate() }
    var state: TestDictationSession.State { session?.state ?? .ready }
    var isActive: Bool { session?.isActive == true }
    var inputAvailable: Bool { context.selectedInputAvailable == true }
    var permissionBlocked: Bool {
        switch context.microphone { case .denied, .restricted: return true; default: return false }
    }
    var profile: String {
        guard let reviewed else { return "" }
        return L10n.format("profiles.recording", reviewed.profileLabel, reviewed.whisper.language)
            + (reviewed.cleanup.localOnly ? " · " + L10n.text("profiles.local_only") : "")
    }
    func open() {
        ensureSession()
        if reviewed == nil { refresh() }
        allowed = canStart()
        if availabilityTimer == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                let value = self.canStart()
                if self.allowed != value { self.allowed = value }
            }
            availabilityTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
    }
    func refresh() {
        guard !isActive else { return }
        ensureSession(); session?.reset()
        let value = configurationProvider()
        reviewed = value; context = contextProvider(value); allowed = canStart(); note = nil
    }
    func start() {
        guard let reviewed else { return }
        ensureSession()
        context = contextProvider(reviewed)
        if permissionBlocked { revision &+= 1; return }
        session?.start(configuration: reviewed, currentConfiguration: configurationProvider(),
            nextRequestConfiguration: nextConfiguration(), inputAvailable: inputAvailable,
            allowed: canStart() && !permissionBlocked, beforeStart: onBegin)
    }
    func stop() { session?.stop() }
    func cancel() { session?.cancel() }
    @discardableResult func close() -> String? {
        availabilityTimer?.invalidate(); availabilityTimer = nil
        let error = session?.close()
        reviewed = nil; note = nil
        return error
    }
    func copyReport() {
        guard let session else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(session.exportReport(version: version), forType: .string)
        note = L10n.text(copied ? "test_dictation.copied" : "diagnosis.copy_failed")
    }
    func openRecordings() {
        guard let directory = session?.recordingsDirectory else { return }
        if !NSWorkspace.shared.open(directory) { note = L10n.text("test_dictation.folder_failed") }
    }
    private func ensureSession() {
        guard let engine = engineProvider() else { allowed = false; return }
        if session?.uses(engine) != true {
            _ = session?.close()
            let value = TestDictationSession(engine: engine)
            value.onChange = { [weak self] in self?.synchronize() }
            session = value
        }
    }
    private func synchronize() {
        if wasActive, !isActive, let reviewed { context = contextProvider(reviewed) }
        wasActive = isActive
        revision &+= 1
    }
}

struct TestDictationView: View {
    @ObservedObject var model: TestDictationViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("test_dictation.title")).font(.title2.bold())
            Text(model.profile).font(.subheadline).foregroundColor(.secondary)
                .accessibilityIdentifier("testDictationProfile")
            if let reason = model.reviewed?.requestProfileSelection?.label {
                Text(reason).font(.caption).foregroundColor(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("test_dictation.consent")).font(.callout)
                    Text(L10n.text(model.reviewed?.history.storeText == false ? "test_dictation.private" : "test_dictation.history"))
                        .font(.callout).foregroundColor(.secondary)
                    Text(L10n.text("test_dictation.audio_policy")).font(.caption).foregroundColor(.secondary)
                    Text(L10n.text(model.reviewed?.cleanup.enabled == false ? "test_dictation.cleanup_local_off" :
                        (model.reviewed?.cleanup.localOnly == true ? "test_dictation.processing_local" : "test_dictation.processing_text")))
                        .font(.caption).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Image(systemName: model.state == .recording ? "mic.circle.fill" : "waveform.circle")
                            .font(.system(size: 28)).foregroundColor(statusColor)
                        Text(L10n.text(statusKey)).font(.headline).accessibilityIdentifier("testDictationStatus")
                        Spacer()
                        if model.state == .recording { LevelMeter(levelDb: model.session?.levelDb ?? -120) }
                        if model.state == .preparing || model.state == .processing { ProgressView().controlSize(.small) }
                    }
                    if let message = blockingMessage {
                        Text(message).foregroundColor(.red).font(.callout).textSelection(.enabled)
                            .accessibilityIdentifier("testDictationError")
                    }
                    if !model.inputAvailable || model.permissionBlocked || isFailure {
                        HStack {
                            Button(L10n.text("test_dictation.microphone_settings")) {
                                model.onSettings(model.permissionBlocked ? .microphonePrivacy : .recordingSettings)
                            }.disabled(model.isActive).accessibilityIdentifier("testMicrophoneSettings")
                            if isFailure, model.session?.configuration != nil {
                                Button(L10n.text("test_dictation.open_recordings")) { model.openRecordings() }
                                    .accessibilityIdentifier("testRecordingsFolder")
                            }
                        }
                    }
                    GroupBox {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            timingRow("test_dictation.preparation", model.session?.timings.preparationSec)
                            timingRow("test_dictation.recording", model.session?.audioDuration)
                            timingRow("test_dictation.transcription", model.session?.timings.transcriptionSec)
                            timingRow("test_dictation.cleanup", model.session?.timings.cleanupSec)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    } label: { Text(L10n.text("test_dictation.timings")).font(.headline) }
                    Text(L10n.text("test_dictation.overlap")).font(.caption).foregroundColor(.secondary)
                    if let result = model.session?.result {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.text(transcriptOriginLabelKey(result,
                                    cleanupEnabled: model.session?.configuration?.cleanup.enabled != false)))
                                    .font(.caption).foregroundColor(.secondary)
                                Text(result.text).font(.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("testDictationResult")
                                if let reason = result.entry?.cleanupFallbackReason {
                                    Text(reason).font(.caption).foregroundColor(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        } label: { Text(L10n.text("test_dictation.preview")).font(.headline) }
                    }
                    if let note = model.note { Text(note).font(.caption).foregroundColor(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 2)
            }
            Divider()
            HStack(spacing: 10) {
                if model.isActive {
                    Button(L10n.text("recording.finish")) { model.stop() }
                        .disabled(model.state == .processing).accessibilityIdentifier("stopTestDictation")
                    Button(L10n.text("common.cancel")) { model.cancel() }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelTestDictation")
                } else if model.state == .ready {
                    Button(L10n.text("test_dictation.start")) { model.start() }
                        .disabled(!model.allowed || !model.inputAvailable || model.permissionBlocked)
                        .accessibilityIdentifier("startTestDictation")
                    Button(L10n.text("test_dictation.refresh")) { model.refresh() }
                        .accessibilityIdentifier("refreshTestDictation")
                } else {
                    Button(L10n.text("test_dictation.new")) { model.refresh() }.accessibilityIdentifier("newTestDictation")
                }
                Spacer()
                if !model.isActive, model.state != .ready {
                    Button(L10n.text("test_dictation.copy_report")) { model.copyReport() }
                        .accessibilityIdentifier("copyTestReport")
                }
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private func timingRow(_ key: String, _ value: TimeInterval?) -> some View {
        GridRow {
            Text(L10n.text(key))
            Text(value.map { L10n.format("test_dictation.seconds", $0) } ?? "—").monospacedDigit()
        }.font(.callout)
    }
    private var isFailure: Bool { if case .failed = model.state { return true }; return false }
    private var blockingMessage: String? {
        if case .failed(let message) = model.state { return message }
        if !model.inputAvailable { return L10n.text("test_dictation.no_input") }
        if model.permissionBlocked { return L10n.text("diagnosis.finding.microphone_denied") }
        if !model.allowed && !model.isActive { return L10n.text("test_dictation.busy") }
        return nil
    }
    private var statusColor: Color {
        if isFailure || model.state == .recording { return .red }
        if model.state == .completed { return .green }
        if model.state == .preparing || model.state == .processing || model.state == .paused { return .orange }
        return .secondary
    }
    private var statusKey: String {
        switch model.state {
        case .ready: return "test_dictation.ready"
        case .preparing: return "test_dictation.preparing"
        case .recording: return "test_dictation.recording_status"
        case .paused: return "overlay.paused"
        case .processing: return "test_dictation.processing"
        case .completed: return "test_dictation.completed"
        case .silence: return "test_dictation.silence"
        case .cancelled: return "test_dictation.cancelled"
        case .failed: return "test_dictation.failed"
        }
    }
}
