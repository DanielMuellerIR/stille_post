import SwiftUI
import StillePostClientCore

struct DictationView: View {
    @ObservedObject var model: MobileModel
    @ObservedObject var localModels: LocalModelController
    @State private var showConnection = false
    @State private var showModels = false
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    processingChoice
                    VStack(spacing: 14) {
                        Image(systemName: model.state.phase == .recording ? "waveform" : "mic.fill")
                            .font(.system(size: 42, weight: .medium)).foregroundStyle(model.state.phase == .recording ? Color.red : Color.accentColor)
                            .frame(height: 60).accessibilityHidden(true)
                        Text(LocalizedStringKey("phase." + model.state.phase.rawValue))
                            .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                            .accessibilityIdentifier("dictation.phase")
                        if model.state.phase == .recording || model.state.recording != nil {
                            Text(Duration.seconds(model.state.elapsed > 0 ? model.state.elapsed : model.state.recording?.duration ?? 0), format: .time(pattern: .minuteSecond))
                                .font(.title.monospacedDigit()).accessibilityIdentifier("dictation.duration")
                        }
                        if model.state.phase == .sending {
                            ProgressView(value: model.state.uploadProgress).accessibilityLabel(Text("upload.progress"))
                            Text(model.state.uploadProgress >= 1 ? "upload.processing" : "upload.sending")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if [.transcribing, .stopping, .cleaning].contains(model.state.phase) {
                            if model.state.phase == .transcribing {
                                Text(LocalizedStringKey("model.phase." + localModels.state.phase.rawValue))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if localModels.state.phase == .recognizing {
                                    ProgressView(value: model.state.transcriptionProgress).accessibilityLabel(Text("offline.progress"))
                                } else { ProgressView() }
                            } else { ProgressView() }
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)

                    if let failure = model.state.failure { failureView(failure) }
                    if let failure = model.setupFailure { failureView(failure) }
                    if let failure = model.state.modelFailure {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(LocalizedStringKey(failure.messageKey), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            Text("recording.retained").font(.footnote).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("dictation.error")
                    }
                    if model.state.recovered { Text("recording.recovered").font(.subheadline).foregroundStyle(.secondary) }
                    if let reply = model.state.reply {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(LocalizedStringKey(reply.origin == "local" ? "result.local" : reply.origin == "raw" ? "result.raw" : "result.title"), systemImage: "text.alignleft").font(.headline)
                            Text(reply.text.isEmpty ? String(localized: "result.empty") : reply.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("dictation.result")
                            Button(action: model.copyResult) {
                                Label(LocalizedStringKey(model.copied ? "result.copied" : "result.copy"), systemImage: model.copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }.buttonStyle(.borderedProminent).disabled(reply.text.isEmpty).accessibilityIdentifier("dictation.copy")
                            Text("result.pasteHint").font(.footnote).foregroundStyle(.secondary)
                            if model.state.localText != nil {
                                if let original = model.state.localText, original != reply.text {
                                    DisclosureGroup("result.localOriginal") { Text(original).textSelection(.enabled) }
                                }
                                Button("result.cleanOnMac", action: model.cleanText)
                                    .frame(minHeight: 44).disabled(!model.canCleanText).accessibilityIdentifier("dictation.cleanText")
                                Text("result.textOnly").font(.footnote).foregroundStyle(.secondary)
                                if !model.hasToken {
                                    Button("connection.configure") { showConnection = true }.frame(minHeight: 44).disabled(model.busy)
                                }
                            }
                        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 18))
                    }

                    actions
                    VStack(alignment: .leading, spacing: 8) {
                        if model.state.mode == .mac {
                            Label(LocalizedStringKey(model.hasToken ? "connection.saved" : "connection.required"), systemImage: model.hasToken ? "desktopcomputer" : "link")
                                .font(.subheadline.weight(.medium))
                        } else {
                            Label(LocalizedStringKey(localModels.state.installed ? "offline.modelReady" : "offline.modelRequired"), systemImage: "cpu")
                                .font(.subheadline.weight(.medium))
                        }
                        Text("recording.limits").font(.footnote).foregroundStyle(.secondary)
                        Text(model.state.mode == .offline ? "privacy.offline" : "privacy.explanation").font(.footnote).foregroundStyle(.secondary)
                        Button { showModels = true } label: {
                            Label("model.manage", systemImage: "cpu").frame(minHeight: 44)
                        }.disabled(model.busy).accessibilityIdentifier("model.open")
                    }
                }.padding(20)
            }.background(Color(.systemGroupedBackground))
                .navigationTitle("Stille Post")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showConnection = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel(Text("connection.title")).accessibilityIdentifier("connection.open").disabled(model.busy)
                    }
                }
                .sheet(isPresented: $showConnection) { ConnectionView(model: model) }
                .sheet(isPresented: $showModels) { LocalModelView(model: localModels) }
                .confirmationDialog("recording.discardConfirm", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("recording.discard", role: .destructive, action: model.discard)
                }
        }
    }

    private var processingChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("dictation.mode", selection: Binding(get: { model.state.mode }, set: { model.select(mode: $0, language: model.state.language) })) {
                Text("dictation.mode.mac").tag(DictationMode.mac)
                Text("dictation.mode.offline").tag(DictationMode.offline)
            }.pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("dictation.mode").disabled(model.busy)
            if model.state.mode == .offline {
                Picker("dictation.language", selection: Binding(get: { model.state.language }, set: { model.select(mode: model.state.mode, language: $0) })) {
                    Text("Deutsch").tag(DictationLanguage.de)
                    Text("English").tag(DictationLanguage.en)
                }.pickerStyle(.menu).frame(minHeight: 44).accessibilityIdentifier("dictation.language").disabled(model.busy)
            }
            Label(LocalizedStringKey(model.state.mode == .offline ? "offline.localOnly" : "connection.encrypted"),
                  systemImage: model.state.mode == .offline ? "iphone" : "lock.shield")
                .font(.footnote).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var actions: some View {
        switch model.state.phase {
        case .recording:
            primary("recording.stop", symbol: "stop.fill", action: model.stop)
            Button("recording.cancel", role: .destructive, action: model.cancel).frame(maxWidth: .infinity, minHeight: 44)
        case .permission:
            ProgressView().frame(maxWidth: .infinity)
            Button("recording.cancel", action: model.cancel).frame(maxWidth: .infinity, minHeight: 44)
        case .sending:
            Button("upload.cancel", action: model.cancel).buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("dictation.cancelUpload")
        case .transcribing, .stopping:
            Button("offline.cancel", action: model.cancel).buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                .disabled(model.state.phase == .stopping).accessibilityIdentifier("dictation.cancelLocal")
            Text("offline.loadHint").font(.footnote).foregroundStyle(.secondary)
        case .cleaning:
            Button("upload.cancel", action: model.cancel).buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
        default:
            if model.state.recording != nil {
                if model.state.reply == nil {
                    if model.state.mode == .offline {
                        primary("offline.transcribe", symbol: "iphone", action: model.transcribe)
                            .disabled(!model.canTranscribe || localModels.state.busy)
                    } else {
                        primary("recording.send", symbol: "arrow.up.circle.fill", action: model.send).disabled(!model.canSend)
                    }
                    if model.state.mode == .mac && !model.hasToken {
                        Button("connection.configure") { showConnection = true }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                Button("recording.discard", role: .destructive) { confirmDiscard = true }.frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.pendingAction).accessibilityIdentifier("dictation.discard")
            } else {
                primary(model.state.reply == nil ? "recording.start" : "recording.again", symbol: "mic.fill", action: model.record)
                    .disabled(model.busy)
            }
        }
    }

    private func primary(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(LocalizedStringKey(key), systemImage: symbol).font(.headline).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("dictation.primary")
    }

    private func failureView(_ failure: ClientFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LocalizedStringKey(failure.messageKey), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            if model.state.recording != nil { Text("recording.retained").font(.footnote).foregroundStyle(.secondary) }
            if failure == .microphoneDenied {
                Button("permissions.openSettings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
        }.accessibilityIdentifier("dictation.error")
    }
}
