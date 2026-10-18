import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StillePostCore

final class AudioImportWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var picker: NSOpenPanel?
    private let model: AudioImportViewModel
    private var observers: [NSObjectProtocol] = []
    var isActive: Bool { model.session?.isActive == true }
    init(engine: @escaping () -> DictationEngine?, configuration: @escaping () -> Config,
         nextConfiguration: @escaping () -> Config, canStart: @escaping () -> Bool,
         onBegin: @escaping () -> Bool, onClosingError: @escaping (String) -> Void) {
        model = AudioImportViewModel(engine: engine, configuration: configuration,
            nextConfiguration: nextConfiguration, canStart: canStart, onBegin: onBegin, onClosingError: onClosingError)
        super.init()
        observers = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if self?.isActive == true { self?.model.cancel() }
            }
        }
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func owns(_ engine: DictationEngine) -> Bool { model.session?.owns(engine) == true }
    func receiveState(_ state: DictationState) { model.session?.receiveState(state) }
    func receiveStage(_ stage: AudioImportStage) { model.session?.receiveStage(stage) }
    func receiveProgress(_ progress: AudioImportProgress) { model.session?.receiveProgress(progress) }
    func receiveResult(_ result: DictationResult) { model.session?.receiveResult(result) }
    func cancel() { model.cancel() }
    @discardableResult func releaseForRegularStart() -> Bool { model.session?.releaseForRegularStart() ?? true }
    func show() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            value.title = L10n.text("audio_import.title")
            value.contentMinSize = NSSize(width: 620, height: 520)
            value.isReleasedWhenClosed = false; value.delegate = self
            value.contentView = NSHostingView(rootView: AudioImportView(model: model, chooseFile: { [weak self] in self?.chooseFile() }))
            value.center(); window = value
        }
        model.open(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func chooseFile() {
        guard let window, !isActive, picker == nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("audio_import.choose")
        panel.prompt = L10n.text("audio_import.select")
        panel.message = L10n.text("audio_import.limits")
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        picker = panel
        let selection = model.beginSelection()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.picker === panel else { return }
            self.picker = nil
            if response == .OK, self.window?.isVisible == true, let url = panel.url {
                self.model.completeSelection(selection, url: url)
            } else { self.model.cancelSelection(selection) }
        }
    }
    func windowWillClose(_ notification: Notification) { picker?.cancel(nil); model.close() }
    func prepareForTermination() { picker?.cancel(nil); model.close(); window?.orderOut(nil) }
}

final class AudioImportViewModel: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var reviewed: Config?
    @Published private(set) var selectedURL: URL?
    @Published private(set) var allowed = false
    @Published private(set) var note: String?
    @Published private(set) var selectionError: String?
    @Published private(set) var isSelecting = false
    private(set) var session: AudioImportSession?
    private let engineProvider: () -> DictationEngine?
    private let configurationProvider: () -> Config
    private let nextConfiguration: () -> Config
    private let canStart: () -> Bool
    private let onBegin: () -> Bool
    private let onClosingError: (String) -> Void
    private var timer: Timer?
    private var scopedURL: URL?
    private var selectionGeneration = UUID()
    private var isVisible = false
    init(engine: @escaping () -> DictationEngine?, configuration: @escaping () -> Config,
         nextConfiguration: @escaping () -> Config, canStart: @escaping () -> Bool,
         onBegin: @escaping () -> Bool, onClosingError: @escaping (String) -> Void) {
        engineProvider = engine; configurationProvider = configuration; self.nextConfiguration = nextConfiguration
        self.canStart = canStart; self.onBegin = onBegin; self.onClosingError = onClosingError
    }
    deinit { timer?.invalidate(); scopedURL?.stopAccessingSecurityScopedResource() }
    var state: AudioImportSession.State { session?.state ?? .ready }
    var isActive: Bool { session?.isActive == true }
    var profile: String {
        guard let reviewed else { return "" }
        return L10n.format("profiles.recording", reviewed.profileLabel, reviewed.whisper.language)
            + (reviewed.cleanup.localOnly ? " · " + L10n.text("profiles.local_only") : "")
    }
    var retentionSummary: String {
        guard let policy = reviewed?.history else { return "" }
        func period(_ days: Int, zero: String) -> String {
            days == 0 ? L10n.text(zero) : (days == 1 ? L10n.text("settings.history.day") : L10n.format("settings.history.days", days))
        }
        let text = policy.storeText ? period(policy.textRetentionDays, zero: "settings.history.unlimited") : L10n.text("audio_import.memory_only")
        return L10n.format("audio_import.retention", text, period(policy.audioRetentionDays, zero: "settings.history.manual"))
    }
    func open() {
        isVisible = true
        ensureSession()
        if reviewed == nil { refresh() }
        if timer == nil {
            let value = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                let ready = self.canStart()
                if self.allowed != ready { self.allowed = ready }
            }
            timer = value; RunLoop.main.add(value, forMode: .common)
        }
    }
    func beginSelection() -> UUID {
        selectionGeneration = UUID(); isSelecting = true; selectionError = nil
        return selectionGeneration
    }
    func cancelSelection(_ generation: UUID) {
        guard selectionGeneration == generation else { return }
        selectionGeneration = UUID(); isSelecting = false
    }
    func cancelPendingSelection() { cancelSelection(selectionGeneration) }
    func completeSelection(_ generation: UUID, url: URL?) {
        guard isVisible, !isActive, selectionGeneration == generation else { return }
        isSelecting = false
        guard let url, validAudioFile(url) else {
            selectedURL = nil; refresh(); selectionError = L10n.text("audio_import.invalid_drop"); return
        }
        selectedURL = url; refresh()
    }
    @discardableResult func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isVisible, !isActive else { return false }
        let generation = beginSelection()
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            completeSelection(generation, url: nil); return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
            let url: URL?
            if error != nil { url = nil }
            else if let value = item as? URL { url = value }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = nil }
            DispatchQueue.main.async { self?.completeSelection(generation, url: url) }
        }
        return true
    }
    private func validAudioFile(_ url: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio),
              let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true else { return false }
        return true
    }
    func refresh() {
        guard !isActive else { return }
        selectionGeneration = UUID(); isSelecting = false; selectionError = nil
        ensureSession(); session?.reset(); reviewed = configurationProvider(); allowed = canStart(); note = nil
    }
    func start() {
        guard !isActive, !isSelecting, let reviewed, let url = selectedURL else { return }
        selectionGeneration = UUID()
        ensureSession()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        session?.start(file: url, configuration: reviewed, currentConfiguration: configurationProvider(),
            nextRequestConfiguration: nextConfiguration(), allowed: canStart(), beforeStart: onBegin)
        synchronize()
    }
    func cancel() { session?.cancel() }
    func close() {
        isVisible = false; selectionGeneration = UUID(); isSelecting = false; selectionError = nil
        timer?.invalidate(); timer = nil
        session?.close(); reviewed = nil; selectedURL = nil; note = nil
        synchronize()
    }
    func copyResult() {
        guard let result = session?.result, result.entry?.isFailed != true, !result.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(result.text, forType: .string)
        note = L10n.text(copied ? "audio_import.copied" : "diagnosis.copy_failed")
    }
    func openRecordings() {
        guard let directory = session?.recordingsDirectory else { return }
        if !NSWorkspace.shared.open(directory) { note = L10n.text("test_dictation.folder_failed") }
    }
    private func ensureSession() {
        guard let engine = engineProvider() else { allowed = false; return }
        if session?.uses(engine) != true {
            session?.close()
            let value = AudioImportSession(engine: engine)
            value.onChange = { [weak self] in self?.synchronize() }
            value.onErrorWhileClosed = onClosingError
            session = value
        }
    }
    private func synchronize() {
        if !isActive, let url = scopedURL { url.stopAccessingSecurityScopedResource(); scopedURL = nil }
        revision &+= 1
    }
}

struct AudioImportView: View {
    @ObservedObject var model: AudioImportViewModel
    let chooseFile: () -> Void
    @State private var dropTargeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("audio_import.title")).font(.title2.bold())
            Text(model.profile).font(.subheadline).foregroundColor(.secondary).lineLimit(2).truncationMode(.middle)
                .accessibilityIdentifier("importProfile")
            if let reason = model.reviewed?.requestProfileSelection?.label {
                Text(reason).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            GroupBox {
                HStack(spacing: 12) {
                    Text(model.selectedURL?.lastPathComponent ?? L10n.text("audio_import.no_file"))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.selectedURL?.path ?? "")
                        .accessibilityIdentifier("importSelectedFile")
                    Button(L10n.text("audio_import.choose"), action: chooseFile)
                        .disabled(model.isActive).accessibilityIdentifier("chooseImportFile")
                }.padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(dropTargeted ? Color.accentColor : Color.clear, lineWidth: 2))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: model.acceptDrop)
            Text(L10n.text(model.isSelecting ? "audio_import.selecting" : "audio_import.drop_hint"))
                .font(.caption).foregroundColor(.secondary).accessibilityIdentifier("importDropHint")
            if let error = model.selectionError {
                Text(error).font(.callout).foregroundColor(.red).accessibilityIdentifier("importDropError")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.text("audio_import.limits")).font(.callout)
                    Text(L10n.text("audio_import.audio_policy")).font(.callout).foregroundColor(.secondary)
                    Text(L10n.text(model.reviewed?.history.storeText == false ? "audio_import.private" : "audio_import.history"))
                        .font(.caption).foregroundColor(.secondary)
                    Text(model.retentionSummary).font(.caption).foregroundColor(.secondary)
                        .accessibilityIdentifier("importRetention")
                    Text(L10n.text(model.reviewed?.cleanup.enabled == false ? "test_dictation.cleanup_local_off" :
                        (model.reviewed?.cleanup.localOnly == true ? "test_dictation.processing_local" : "test_dictation.processing_text")))
                        .font(.caption).foregroundColor(.secondary)
                    Divider()
                    HStack(spacing: 12) {
                        if model.isActive { ProgressView().controlSize(.small) }
                        Text(L10n.text(statusKey)).font(.headline).accessibilityIdentifier("audioImportStatus")
                    }
                    if let progress = model.session?.progress {
                        VStack(alignment: .leading, spacing: 6) {
                            if let fraction = progress.fraction { ProgressView(value: fraction) }
                            Text(progressLabel(progress)).font(.caption).foregroundColor(.secondary)
                                .accessibilityIdentifier("audioImportProgress")
                        }
                    }
                    if let error = errorMessage {
                        Text(error).font(.callout).foregroundColor(.red).textSelection(.enabled)
                            .accessibilityIdentifier("audioImportError")
                        if model.session?.configuration != nil {
                            Button(L10n.text("audio_import.open_audio")) { model.openRecordings() }
                                .accessibilityIdentifier("importAudioFolder")
                        }
                    } else if !model.allowed && !model.isActive {
                        Text(L10n.text("test_dictation.busy")).font(.callout).foregroundColor(.secondary)
                    }
                    if model.session?.result?.entry?.audioIsComplete == false {
                        Text(L10n.text("audio_import.incomplete_audio")).font(.callout).foregroundColor(.orange)
                    }
                    if let result = model.session?.result {
                        let partial = result.entry?.isFailed == true
                        let text = partial ? result.entry?.rawText ?? "" : result.text
                        if !text.isEmpty {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L10n.text(transcriptOriginLabelKey(result,
                                        cleanupEnabled: model.session?.configuration?.cleanup.enabled != false, partial: partial)))
                                        .font(.caption).foregroundColor(.secondary)
                                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        .accessibilityIdentifier("audioImportResult")
                                    if let reason = result.entry?.cleanupFallbackReason { Text(reason).font(.caption).foregroundColor(.secondary) }
                                }.padding(6)
                            } label: { Text(L10n.text("test_dictation.preview")).font(.headline) }
                        }
                    }
                    if let note = model.note { Text(note).font(.caption).foregroundColor(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                if model.isActive {
                    Button(L10n.text("common.cancel")) { model.cancel() }
                        .keyboardShortcut(.cancelAction).disabled(model.state == .cancelling)
                        .accessibilityIdentifier("cancelAudioImport")
                } else if model.isSelecting {
                    Button(L10n.text("common.cancel")) { model.cancelPendingSelection() }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelAudioSelection")
                } else if model.state == .ready {
                    Button(L10n.text("audio_import.start")) { model.start() }
                        .disabled(!model.allowed || model.isSelecting || model.selectedURL == nil).accessibilityIdentifier("startAudioImport")
                    Button(L10n.text("audio_import.refresh")) { model.refresh() }
                        .accessibilityIdentifier("refreshAudioImport")
                } else {
                    Button(L10n.text("audio_import.new")) { model.refresh() }.accessibilityIdentifier("newAudioImport")
                }
                Spacer()
                if !model.isActive, let result = model.session?.result, result.entry?.isFailed != true, !result.text.isEmpty {
                    Button(L10n.text("audio_import.copy")) { model.copyResult() }.accessibilityIdentifier("copyAudioImport")
                }
            }
        }.padding(20).environment(\.locale, Locale(identifier: L10n.languageCode))
    }
    private var errorMessage: String? { if case .failed(let message) = model.state { return message }; return nil }
    private func progressLabel(_ value: AudioImportProgress) -> String {
        func time(_ seconds: TimeInterval) -> String {
            let rounded = max(0, Int(seconds)); return String(format: "%d:%02d", rounded / 60, rounded % 60)
        }
        if value.stage == .decoding {
            if let total = value.totalSeconds { return L10n.format("audio_import.decode_progress", time(value.audioSeconds), time(total)) }
            return L10n.format("audio_import.decode_progress_unknown", time(value.audioSeconds))
        }
        let segments = value.completedSegments == 1 ? L10n.text("audio_import.segment_one") :
            L10n.format("audio_import.segment_many", value.completedSegments)
        return L10n.format("audio_import.transcribe_progress", time(value.audioSeconds), time(value.totalSeconds ?? 0), segments)
    }
    private var statusKey: String {
        switch model.state {
        case .ready: return "audio_import.ready"
        case .processing(.decoding): return "audio_import.decoding"
        case .processing(.transcribing): return "audio_import.transcribing"
        case .processing(.cleaning): return "audio_import.finishing"
        case .cancelling: return "audio_import.cancelling"
        case .completed: return "audio_import.completed"
        case .silence: return "audio_import.silence"
        case .cancelled: return "audio_import.cancelled"
        case .failed: return "audio_import.failed"
        }
    }
}
