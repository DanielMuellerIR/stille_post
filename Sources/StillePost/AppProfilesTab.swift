import AppKit
import SwiftUI
import UniformTypeIdentifiers
import StillePostCore

struct AppProfilesTab: View {
    @Binding var config: Config
    @State private var bundleID = ""
    @State private var profileID: UUID?

    var body: some View {
        Form {
            Section {
                Text(L10n.text("app_profiles.help")).fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(L10n.text("app_profiles.bundle_id"), text: $bundleID)
                        .accessibilityIdentifier("appProfileBundleID")
                    Button(L10n.text("app_profiles.choose_app"), action: chooseApplication)
                }
                Picker(L10n.text("app_profiles.profile"), selection: $profileID) {
                    Text(L10n.text("profiles.choose")).tag(nil as UUID?)
                    ForEach(config.profiles) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("appProfileNewSelection")
                Button(L10n.text("app_profiles.add")) {
                    if let profileID { config.appProfiles[bundleID] = profileID; bundleID = "" }
                }
                .disabled(!Config.validAppBundleID(bundleID) || profileID == nil || config.appProfiles[bundleID] != nil || config.appProfiles.count >= 200)
                .accessibilityIdentifier("appProfileAdd")
                if config.profiles.isEmpty { Text(L10n.text("app_profiles.no_profiles")).foregroundColor(.secondary) }
            }
            Section(L10n.text("app_profiles.rules")) {
                if config.appProfiles.isEmpty { Text(L10n.text("app_profiles.empty")).foregroundColor(.secondary) }
                ForEach(config.appProfiles.keys.sorted(), id: \.self) { app in
                    HStack {
                        Text(verbatim: app).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Picker(L10n.text("app_profiles.profile"), selection: Binding(
                            get: { config.appProfiles[app] ?? UUID.zero },
                            set: { config.appProfiles[app] = $0 })) {
                            if let id = config.appProfiles[app], !config.profiles.contains(where: { $0.id == id }) {
                                Text(L10n.text("app_profiles.missing")).tag(id)
                            }
                            ForEach(config.profiles) { Text(verbatim: $0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 210).accessibilityIdentifier("appProfile." + app)
                        Button(L10n.text("common.delete"), role: .destructive) { config.appProfiles.removeValue(forKey: app) }
                            .accessibilityIdentifier("removeAppProfile." + app)
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { bundleID = id }
        }
    }
}

private extension UUID {
    static let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
