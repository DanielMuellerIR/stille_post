import SwiftUI
import StillePostClientCore

struct DictationView: View {
    @ObservedObject var model: MobileModel
    @State private var showConnection = false
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    developmentNotice
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
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)

                    if let failure = model.state.failure { failureView(failure) }
                    if let failure = model.setupFailure { failureView(failure) }
                    if model.state.recovered { Text("recording.recovered").font(.subheadline).foregroundStyle(.secondary) }
                    if let reply = model.state.reply {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(LocalizedStringKey(reply.origin == "raw" ? "result.raw" : "result.title"), systemImage: "text.alignleft").font(.headline)
                            Text(reply.text.isEmpty ? String(localized: "result.empty") : reply.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("dictation.result")
                            Button(action: model.copyResult) {
                                Label(LocalizedStringKey(model.copied ? "result.copied" : "result.copy"), systemImage: model.copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }.buttonStyle(.borderedProminent).disabled(reply.text.isEmpty).accessibilityIdentifier("dictation.copy")
                            Text("result.pasteHint").font(.footnote).foregroundStyle(.secondary)
                        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 18))
                    }

                    actions
                    VStack(alignment: .leading, spacing: 8) {
                        Label(LocalizedStringKey(model.hasToken ? "connection.saved" : "connection.required"), systemImage: model.hasToken ? "desktopcomputer" : "link")
                            .font(.subheadline.weight(.medium))
                        Text("recording.limits").font(.footnote).foregroundStyle(.secondary)
                        Text("privacy.explanation").font(.footnote).foregroundStyle(.secondary)
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
                .confirmationDialog("recording.discardConfirm", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("recording.discard", role: .destructive, action: model.discard)
                }
        }
    }

    private var developmentNotice: some View {
        Label("connection.encrypted", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
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
        default:
            if model.state.recording != nil {
                if model.state.reply == nil {
                    primary("recording.send", symbol: "arrow.up.circle.fill", action: model.send).disabled(!model.canSend)
                    if !model.hasToken || !model.configuration.allowInsecureDevelopment {
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
