import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import StillePostCore

@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: DiagnosticsModel
    init(configuration: @escaping () -> Config, bridgeState: @escaping () -> DiagnosticContext.BridgeState,
         onAction: @escaping (DiagnosticFinding.Action) -> Void) {
        model = DiagnosticsModel(configuration: configuration, bridgeState: bridgeState, onAction: onAction)
        super.init()
    }
    func show() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            value.title = L10n.text("diagnosis.title")
            value.contentMinSize = NSSize(width: 600, height: 480)
            value.isReleasedWhenClosed = false
            value.delegate = self
            value.contentView = NSHostingView(rootView: DiagnosticsView(model: model))
            value.center(); window = value
        }
        model.start()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var report: DiagnosticReport?
    @Published private(set) var checking = false
    @Published private(set) var profile = ""
    @Published private(set) var note: String?
    private let configuration: () -> Config
    private let bridgeState: () -> DiagnosticContext.BridgeState
    let onAction: (DiagnosticFinding.Action) -> Void
    private let service: DiagnosticsService
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(configuration: @escaping () -> Config, bridgeState: @escaping () -> DiagnosticContext.BridgeState,
         onAction: @escaping (DiagnosticFinding.Action) -> Void, service: DiagnosticsService = .init()) {
        self.configuration = configuration; self.bridgeState = bridgeState
        self.onAction = onAction; self.service = service
    }
    func start() {
        task?.cancel()
        generation = UUID(); let current = generation
        let config = configuration()
        profile = L10n.format("profiles.recording", config.profileLabel, config.whisper.language)
        if config.cleanup.localOnly { profile += " · " + L10n.text("profiles.local_only") }
        var context = DiagnosticContext()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: context.microphone = .authorized
        case .notDetermined: context.microphone = .notDetermined
        case .denied: context.microphone = .denied
        case .restricted: context.microphone = .restricted
        @unknown default: context.microphone = .unknown
        }
        context.selectedInputAvailable = config.audio.inputDeviceUID.isEmpty
            ? AudioInputDeviceCatalog.defaultDevice() != nil
            : AudioInputDeviceCatalog.availableDevices().contains { $0.uid == config.audio.inputDeviceUID }
        context.accessibility = AXIsProcessTrusted()
        context.keyboardReadable = HotkeyManager.canReadKeyboardState
        context.bridge = bridgeState()
        report = nil; note = nil; checking = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.service.scan(configuration: config, context: context)
                guard self.generation == current, !Task.isCancelled else { return }
                self.report = value
            } catch {
                guard self.generation == current, !Task.isCancelled else { return }
                self.note = L10n.text("diagnosis.failed")
            }
            guard self.generation == current else { return }
            self.checking = false; self.task = nil
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; checking = false
        note = L10n.text("diagnosis.cancelled")
    }
    func copyReport() {
        guard let report else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(report.export(version: version), forType: .string)
        note = L10n.text(copied ? "diagnosis.copied" : "diagnosis.copy_failed")
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("diagnosis.title")).font(.title2.bold())
            Text(model.profile).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityIdentifier("diagnosisProfile")
            Text(L10n.text("diagnosis.privacy")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(L10n.text("diagnosis.start")) { model.start() }
                    .disabled(model.checking).accessibilityIdentifier("diagnosisStart")
                if model.checking {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("common.cancel")) { model.cancel() }.accessibilityIdentifier("diagnosisCancel")
                }
                Spacer()
                Button(L10n.text("diagnosis.copy")) { model.copyReport() }
                    .disabled(model.report == nil).accessibilityIdentifier("diagnosisCopy")
            }
            if let note = model.note { Text(note).font(.callout).accessibilityIdentifier("diagnosisNote") }
            if let report = model.report {
                Text(L10n.text(report.problemCount > 0 ? "diagnosis.blocked" : "diagnosis.checked"))
                    .font(.headline).accessibilityIdentifier("diagnosisSummary")
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(DiagnosticFinding.Category.allCases, id: \.self) { category in
                            let rows = report.findings.filter { $0.category == category }
                            if !rows.isEmpty {
                                GroupBox {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(rows) { finding in
                                            HStack(alignment: .top, spacing: 10) {
                                                Image(systemName: symbol(finding.level))
                                                    .foregroundStyle(color(finding.level)).frame(width: 20)
                                                Text(finding.message).frame(maxWidth: .infinity, alignment: .leading)
                                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                                if finding.action != .none {
                                                    Button(L10n.text(finding.action == .microphonePrivacy || finding.action == .accessibilityPrivacy ? "diagnosis.system_settings" : "diagnosis.settings")) {
                                                        model.onAction(finding.action)
                                                    }
                                                    .accessibilityIdentifier("diagnosisAction." + finding.id)
                                                }
                                            }
                                            .font(.callout)
                                            .accessibilityElement(children: .contain)
                                            .accessibilityIdentifier("diagnosis." + finding.id)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                } label: { Text(L10n.text("diagnosis.category." + category.rawValue)).font(.headline) }
                            }
                        }
                    }.padding(.trailing, 2)
                }
            } else { Spacer() }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func symbol(_ level: DiagnosticFinding.Level) -> String {
        switch level {
        case .ready: return "checkmark.circle.fill"
        case .problem: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        case .information: return "info.circle"
        }
    }
    private func color(_ level: DiagnosticFinding.Level) -> Color {
        switch level {
        case .ready: return .green
        case .problem: return .red
        case .warning: return .orange
        case .unknown: return .secondary
        case .information: return .blue
        }
    }
}
