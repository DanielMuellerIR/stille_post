import SwiftUI
import StillePostClientCore

struct LocalModelView: View {
    @ObservedObject var model: LocalModelController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false
    @State private var showLicense = false
    @State private var licenseText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Whisper large-v3-turbo", systemImage: "cpu").font(.headline)
                    LabeledContent("model.downloadSize", value: size(model.state.totalBytes))
                    Text("model.description").font(.footnote).foregroundStyle(.secondary)
                    Text("model.storageHint").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Label(LocalizedStringKey("model.phase." + model.state.phase.rawValue), systemImage: stateSymbol)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("model.phase")
                    if model.state.phase == .downloading {
                        ProgressView(value: Double(model.state.downloadedBytes), total: Double(max(1, model.state.totalBytes)))
                            .accessibilityLabel(Text("model.progress"))
                        Text(size(model.state.downloadedBytes) + " / " + size(model.state.totalBytes))
                            .font(.subheadline.monospacedDigit()).accessibilityIdentifier("model.progress")
                    } else if model.state.busy { ProgressView() }
                    if [.loading, .validating, .stopping].contains(model.state.phase) {
                        Text(model.state.phase == .stopping ? "model.stopHint" : "model.loadHint")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if [.downloading, .validating, .loading].contains(model.state.phase) {
                        Text("model.awakeHint").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let failure = model.state.failure {
                        Label(LocalizedStringKey(failure.messageKey), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).accessibilityElement(children: .combine)
                            .accessibilityIdentifier("model.error")
                    }
                    if let notice = model.state.notice {
                        Text(LocalizedStringKey("model.notice." + notice.rawValue)).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("model.status") }
                Section {
                    if model.state.phase == .downloading {
                        Button("model.pause") { model.interrupt(.paused) }.accessibilityIdentifier("model.pause")
                    } else if [.loading, .validating].contains(model.state.phase) {
                        Button("model.cancel") { model.interrupt(.paused) }.accessibilityIdentifier("model.cancel")
                    } else if model.state.phase == .loaded {
                        Button("model.release", action: model.release).accessibilityIdentifier("model.release")
                    } else if model.state.installed {
                        Button("model.load", action: model.load).disabled(model.state.busy).accessibilityIdentifier("model.load")
                    } else {
                        Button(model.state.downloadedBytes > 0 ? "model.resume" : "model.download", action: model.download)
                            .disabled(model.state.busy || model.state.totalBytes == 0).accessibilityIdentifier("model.download")
                    }
                    if model.state.installed || model.state.downloadedBytes > 0 {
                        Button("model.remove", role: .destructive) { confirmRemoval = true }
                            .disabled(model.state.busy).accessibilityIdentifier("model.remove")
                    }
                }
                Section {
                    Text("model.currentUse").font(.footnote).foregroundStyle(.secondary)
                    Button("model.license") {
                        if let url = Bundle.main.url(forResource: "LocalModelLicenses", withExtension: "txt") {
                            licenseText = (try? String(contentsOf: url, encoding: .utf8)) ?? String(localized: "model.error.catalog")
                        }
                        showLicense = true
                    }
                }
            }
            .navigationTitle("model.title").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { model.interrupt(.closed); dismiss() } } }
            .task { model.refresh() }
            .onDisappear { model.interrupt(.closed) }
            .confirmationDialog("model.removeConfirm", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("model.remove", role: .destructive, action: model.remove)
            }
            .sheet(isPresented: $showLicense) {
                NavigationStack {
                    ScrollView { Text(licenseText).font(.footnote).textSelection(.enabled).padding(20) }
                        .navigationTitle("model.license")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { showLicense = false } } }
                }
            }
        }
    }

    private var stateSymbol: String {
        switch model.state.phase {
        case .loaded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        case .available: return "internaldrive"
        default: return "arrow.down.circle"
        }
    }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
