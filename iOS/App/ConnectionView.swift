import SwiftUI
import StillePostClientCore

struct ConnectionView: View {
    @ObservedObject var model: MobileModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var token = ""
    @State private var development = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("connection.address", text: $address, prompt: Text("http://mac-name.local:8188"))
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("connection.address")
                    SecureField(model.hasToken ? "connection.tokenReplace" : "connection.token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityIdentifier("connection.token")
                    Text(model.hasToken ? "connection.tokenStored" : "connection.tokenHint").font(.footnote).foregroundStyle(.secondary)
                } header: { Text("connection.mac") } footer: { Text("connection.addressHint") }
                Section {
                    #if DEBUG
                    Toggle("development.allow", isOn: $development).accessibilityIdentifier("connection.development")
                    #endif
                    Text("development.explanation").font(.footnote).foregroundStyle(.secondary)
                }
                if let failure = model.setupFailure { Section { Text(LocalizedStringKey(failure.messageKey)).foregroundStyle(.red) } }
                Section {
                    Button(saved ? "connection.savedChanges" : "connection.save") {
                        Task {
                            saved = await model.save(configuration: BridgeConfiguration(address: address, allowInsecureDevelopment: development), token: token)
                            if saved { token = "" }
                        }
                    }.disabled(model.busy).accessibilityIdentifier("connection.save")
                    Button("connection.check", action: model.checkConnection)
                        .disabled(model.busy || !model.hasToken || !savedConfigurationMatches).accessibilityIdentifier("connection.check")
                    connectionStatus
                }
                if model.hasToken {
                    Section {
                        Button("connection.forget", role: .destructive) {
                            Task { await model.forgetConnection(); address = model.configuration.address; token = ""; development = false; saved = false }
                        }.disabled(model.busy)
                    }
                }
                Section { Text("shortcut.hint").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("connection.title").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { token = ""; dismiss() } } }
                .onAppear { address = model.configuration.address; development = model.configuration.allowInsecureDevelopment }
                .onChange(of: address) { _, _ in saved = false }
                .onChange(of: token) { _, value in if !value.isEmpty { saved = false } }
                .onChange(of: development) { _, _ in saved = false }
        }
    }

    private var savedConfigurationMatches: Bool {
        address == model.configuration.address && development == model.configuration.allowInsecureDevelopment && token.isEmpty
    }

    @ViewBuilder private var connectionStatus: some View {
        switch model.connection {
        case .unchecked: Text("connection.unchecked").foregroundStyle(.secondary)
        case .checking: ProgressView("connection.checking")
        case .ready(let version): Label(String(format: String(localized: "connection.ready"), version), systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let failure): Text(LocalizedStringKey(failure.messageKey)).foregroundStyle(.red)
        }
    }
}
