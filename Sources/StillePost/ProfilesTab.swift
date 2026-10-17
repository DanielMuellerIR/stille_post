import SwiftUI
import StillePostCore

struct ProfilesTab: View {
    @Binding var config: Config
    @State private var selected: UUID?
    @State private var section = Section.language

    private enum Section: String, CaseIterable {
        case language, vocabulary, cleanup, history
        var title: String { L10n.text("profiles." + rawValue) }
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("profiles.help")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(L10n.text("profiles.default"), selection: $config.defaultProfileID) {
                    Text(L10n.text("profiles.global")).tag(nil as UUID?)
                    ForEach(config.profiles) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("profileDefault")
                HStack {
                    Picker(L10n.text("profiles.edit"), selection: $selected) {
                        Text(L10n.text("profiles.choose")).tag(nil as UUID?)
                        ForEach(config.profiles) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("profileEditorSelection")
                    Button(L10n.text("profiles.new")) {
                        let profile = Config.Profile(name: L10n.text("profiles.new_name"))
                        config.profiles.append(profile)
                        selected = profile.id
                    }
                    .disabled(config.profiles.count >= 50)
                    .accessibilityIdentifier("profileNew")
                    Button(L10n.text("common.delete"), role: .destructive) {
                        if let selected { config.removeProfile(id: selected) }
                        selected = nil
                    }
                    .disabled(selected == nil)
                    .accessibilityIdentifier("profileDelete")
                }
            }
            .padding(.horizontal, 20)
            if let selected, let profile = config.profiles.first(where: { $0.id == selected }) {
                let binding = Binding<Config.Profile>(get: {
                    config.profiles.first(where: { $0.id == selected }) ?? profile
                }, set: { updated in
                    if let index = config.profiles.firstIndex(where: { $0.id == selected }) { config.profiles[index] = updated }
                })
                HStack {
                    Text(L10n.text("profiles.name"))
                    TextField("", text: binding.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.text("profiles.name"))
                        .accessibilityIdentifier("profileName")
                }.padding(.horizontal, 20)
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 20)
                editor(binding).id(selected)
            } else {
                Spacer()
                Text(L10n.text("profiles.choose_help")).foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.top, 8)
        .onAppear { selected = config.activeProfile?.id ?? config.profiles.first?.id }
    }

    @ViewBuilder private func editor(_ profile: Binding<Config.Profile>) -> some View {
        switch section {
        case .language:
            Form {
                Toggle(L10n.text("profiles.inherit"), isOn: inherited(profile.language, initial: config.whisper.language))
                    .accessibilityIdentifier("profileInheritLanguage")
                TextField(L10n.text("settings.whisper.language"), text: Binding(
                    get: { profile.wrappedValue.language ?? config.whisper.language },
                    set: { profile.wrappedValue.language = $0 }))
                    .disabled(profile.wrappedValue.language == nil)
                    .accessibilityIdentifier("profileLanguage")
                Text(L10n.text("settings.whisper.language_help")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.formStyle(.grouped)
        case .vocabulary:
            Form {
                Toggle(L10n.text("profiles.inherit"), isOn: inherited(profile.vocabulary, initial: Config.Vocabulary(config.cleanup)))
                VocabularyEditor(cleanup: Binding(get: {
                    profile.wrappedValue.vocabulary?.applying(to: config.cleanup) ?? config.cleanup
                }, set: { profile.wrappedValue.vocabulary = Config.Vocabulary($0) }))
                    .disabled(profile.wrappedValue.vocabulary == nil)
                    .id(profile.wrappedValue.vocabulary == nil)
                Text(L10n.text("profiles.vocabulary_help")).font(.caption).foregroundColor(.secondary)
            }.formStyle(.grouped)
        case .cleanup:
            Toggle(L10n.text("profiles.inherit"), isOn: inherited(profile.cleanup, initial: Config.CleanupOptions(config.cleanup)))
                .padding(.horizontal, 20)
            CleanupTab(cleanup: Binding(get: {
                profile.wrappedValue.cleanup?.applying(to: config.cleanup) ?? config.cleanup
            }, set: { updated in
                var options = Config.CleanupOptions(updated)
                if profile.wrappedValue.cleanup?.localOnly == nil && updated.localOnly == config.cleanup.localOnly {
                    options.localOnly = nil
                }
                profile.wrappedValue.cleanup = options
            }), showsVocabulary: false)
                .disabled(profile.wrappedValue.cleanup == nil)
        case .history:
            Toggle(L10n.text("profiles.inherit"), isOn: inherited(profile.history, initial: config.history))
                .padding(.horizontal, 20)
            HistorySettingsTab(history: Binding(get: { profile.wrappedValue.history ?? config.history },
                set: { profile.wrappedValue.history = $0 }))
                .disabled(profile.wrappedValue.history == nil)
        }
    }

    private func inherited<T>(_ value: Binding<T?>, initial: T) -> Binding<Bool> {
        Binding(get: { value.wrappedValue == nil }, set: { value.wrappedValue = $0 ? nil : initial })
    }
}
