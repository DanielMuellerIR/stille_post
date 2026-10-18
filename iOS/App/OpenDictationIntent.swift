import AppIntents

struct OpenDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "shortcut.title"
    static let description = IntentDescription("shortcut.description")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct DictationShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenDictationIntent(), phrases: ["Open dictation in \(.applicationName)"],
                    shortTitle: "shortcut.title", systemImageName: "mic")
    }
}
