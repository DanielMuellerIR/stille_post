import AppKit
import SwiftUI
import StillePostCore

/// Ein Editor arbeitet mit seinem Öffnungs-Snapshot. Ein Konflikt erhält den
/// Entwurf, eine Löschung oder Textfrist entfernt dagegen auch seine RAM-Kopien.
final class HistoryEditorModel: ObservableObject, Identifiable {
    let id: UUID
    private let history: HistoryStore
    let vocabularyScopeLabel: String
    private let vocabularyProfileID: UUID?
    private let onVocabularySaved: (Config) -> Void
    @Published private(set) var snapshot: HistoryStore.Entry?
    @Published var draft: String { didSet { scheduleComparison() } }
    @Published private(set) var saving = false
    @Published private(set) var comparing = false
    @Published private(set) var difference: TextDifference.Result?
    @Published private(set) var errorMessage: String?
    @Published var vocabularyTerm = "" { didSet { vocabularyConfirmed = false; vocabularySaved = false } }
    @Published var vocabularyVariant = "" { didSet { vocabularyConfirmed = false; vocabularySaved = false } }
    @Published var vocabularyConfirmed = false
    @Published private(set) var vocabularySaved = false
    @Published private(set) var recleaning = false
    @Published private(set) var candidate: HistoryRecleanup.Candidate?
    private var recleanupTask: Task<Void, Never>?
    private var recleanupGeneration: UInt64 = 0
    private var comparisonGeneration: UInt64 = 0
    private var comparisonTask: Task<Void, Never>?
    private var comparisonWorker: Task<TextDifference.Result, Error>?
    private(set) var saveTask: Task<Void, Never>?

    init(entry: HistoryStore.Entry, history: HistoryStore, onVocabularySaved: @escaping (Config) -> Void = { _ in }) {
        id = entry.id
        snapshot = entry
        draft = entry.cleanText
        self.history = history
        let config = Config.load()
        self.vocabularyProfileID = config.vocabularyProfileID
        self.vocabularyScopeLabel = config.vocabularyProfileID == nil ? L10n.text("profiles.global") : config.profileLabel
        self.onVocabularySaved = onVocabularySaved
        scheduleComparison()
    }

    deinit { comparisonTask?.cancel(); comparisonWorker?.cancel(); recleanupTask?.cancel() }

    var hasChanges: Bool { snapshot.map { !HistoryStore.sameText($0.cleanText, draft) } ?? false }
    var reviewingCleanup: Bool { recleaning || candidate != nil }

    @discardableResult
    func copy(_ text: String, write: @escaping (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                // Ein anderer Prozess erreicht unseren lokalen onChange-Callback
                // nicht. Vor dem Export deshalb frisch nach Verfügbarkeit fragen.
                let entries = try await history.listAsync()
                reconcile(entries)
                guard snapshot?.canEdit == true else { return }
                write(text)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func save() {
        expireIfNeeded()
        guard !saving, !reviewingCleanup, let expected = snapshot, expected.canEdit, hasChanges else { return }
        saving = true
        errorMessage = nil
        let text = draft
        saveTask = Task { @MainActor in
            defer { saving = false; saveTask = nil }
            do {
                let receipt = try await history.saveCorrectionAsync(text, expected: expected)
                guard snapshot != nil else { return }
                snapshot = receipt
                draft = receipt.cleanText
            } catch {
                errorMessage = error.localizedDescription
                // Bei inzwischen gelöschtem/abgelaufenem Text keine Entwurfskopie
                // behalten. Ein reiner Optimismuskonflikt bleibt kopierbar.
                if let entries = try? await history.listAsync() { reconcile(entries) }
            }
        }
    }

    func captureSelectedTerm() {
        guard !saving, snapshot?.canEdit == true else { return }
        vocabularySaved = false
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           HistoryStore.sameText(textView.string, draft),
           let range = Range(textView.selectedRange(), in: draft), !range.isEmpty {
            vocabularyTerm = String(draft[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func saveVocabulary() {
        expireIfNeeded()
        guard !saving, vocabularyConfirmed, let expected = snapshot, expected.canEdit else { return }
        let term = vocabularyTerm, variant = vocabularyVariant
        saving = true
        errorMessage = nil
        vocabularySaved = false
        saveTask = Task { @MainActor in
            defer { saving = false; saveTask = nil }
            do {
                let saved = try await history.withEditableSnapshotAsync(expected: expected) {
                    try ConfigFile().addVocabulary(term: term, variant: variant, profileID: self.vocabularyProfileID)
                }
                onVocabularySaved(saved)
                vocabularySaved = true
                vocabularyConfirmed = false
            } catch {
                errorMessage = error.localizedDescription
                if let entries = try? await history.listAsync() { reconcile(entries) }
            }
        }
    }

    func startRecleanup() {
        expireIfNeeded()
        guard !saving, !recleaning, candidate == nil, let expected = snapshot, expected.canEdit else { return }
        recleanupGeneration &+= 1
        let generation = recleanupGeneration
        recleaning = true
        errorMessage = nil
        recleanupTask = Task { @MainActor in
            do {
                let result = try await HistoryRecleanup.run(expected: expected, history: history)
                guard generation == recleanupGeneration, snapshot != nil else { return }
                candidate = result
            } catch {
                guard generation == recleanupGeneration else { return }
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
                if let entries = try? await history.listAsync() { reconcile(entries) }
            }
            guard generation == recleanupGeneration else { return }
            recleaning = false
            recleanupTask = nil
        }
    }

    func discardRecleanup() {
        recleanupGeneration &+= 1
        recleanupTask?.cancel()
        recleanupTask = nil
        recleaning = false
        candidate = nil
    }

    func acceptRecleanup() {
        expireIfNeeded()
        guard !saving, let candidate, snapshot?.canEdit == true else { return }
        saving = true
        errorMessage = nil
        saveTask = Task { @MainActor in
            defer { saving = false; saveTask = nil }
            do {
                let receipt = try await history.saveRecleanupAsync(candidate.result, durationSec: candidate.durationSec,
                                                                  expected: candidate.expected)
                guard snapshot != nil else { return }
                snapshot = receipt
                draft = receipt.cleanText
                self.candidate = nil
            } catch {
                errorMessage = error.localizedDescription
                if let entries = try? await history.listAsync() { reconcile(entries) }
            }
        }
    }

    func reconcile(_ entries: [HistoryStore.Entry]) {
        guard snapshot != nil else { return }
        guard entries.contains(where: { $0.id == id && $0.canEdit }) else { invalidate(); return }
        expireIfNeeded()
    }

    func expireIfNeeded() {
        if let snapshot, !snapshot.canEdit { invalidate() }
    }

    private func invalidate() {
        stopComparison()
        discardRecleanup()
        vocabularyTerm = ""
        vocabularyVariant = ""
        vocabularyConfirmed = false
        vocabularySaved = false
        snapshot = nil
        draft = ""
        difference = nil
        errorMessage = L10n.text("core.history.correction_unavailable")
    }

    func stopComparison() {
        comparisonGeneration &+= 1
        comparisonTask?.cancel()
        comparisonWorker?.cancel()
        comparing = false
    }

    private func scheduleComparison() {
        stopComparison()
        difference = nil
        guard let snapshot else { return }
        let generation = comparisonGeneration
        let before = snapshot.rawText, after = draft
        comparing = true
        comparisonTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                guard let self, generation == self.comparisonGeneration else { return }
                let worker = Task.detached(priority: .userInitiated) { try TextDifference.compare(before, after) }
                self.comparisonWorker = worker
                let result = try await worker.value
                guard generation == self.comparisonGeneration, self.snapshot != nil else { return }
                self.difference = result
                self.comparing = false
            } catch {
                guard let self, generation == self.comparisonGeneration else { return }
                self.comparing = false
            }
        }
    }
}

struct HistoryEditorView: View {
    @ObservedObject var model: HistoryEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedVersion = "raw"
    @State private var selectedTab = "text"

    private struct Version: Identifiable {
        let id: String
        let title: String
        let text: String
        let origin: HistoryStore.Entry.ResultOrigin?
    }

    private var versions: [Version] {
        guard let entry = model.snapshot else { return [] }
        var result = [Version(id: "raw", title: L10n.text("editor.raw"), text: entry.rawText, origin: nil),
                      Version(id: "original", title: L10n.text("editor.original"),
                              text: entry.originalCleanText ?? entry.cleanText, origin: entry.originalResultOrigin)]
        for (index, revision) in (entry.previousResults ?? []).enumerated() {
            result.append(Version(id: "previous-\(index)", title: L10n.format("editor.previous", index + 1) + " · " + EntryRow.dateFormatter.string(from: revision.date),
                                  text: revision.text, origin: revision.origin))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("editor.title")).font(.title2.bold())
                Spacer()
                if let entry = model.snapshot {
                    Text(EntryRow.dateFormatter.string(from: entry.date)).font(.caption).foregroundColor(.secondary)
                }
            }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("historyCorrectionError")
            }
            if let entry = model.snapshot {
                Text(L10n.text("editor.origin.\(entry.resultOrigin.rawValue)"))
                    .font(.callout).foregroundColor(.secondary)
                TabView(selection: $selectedTab) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("editor.text_help")).font(.caption).foregroundColor(.secondary)
                        Button(L10n.text("editor.vocabulary.add")) {
                            model.captureSelectedTerm()
                            selectedTab = "vocabulary"
                        }
                        .disabled(model.saving || model.reviewingCleanup)
                        TextEditor(text: $model.draft)
                            .font(.body)
                            .disableAutocorrection(true)
                            .accessibilityIdentifier("historyCorrectionText")
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                            .disabled(model.saving || model.reviewingCleanup)
                    }
                    .padding(12)
                    .tabItem { Text(L10n.text("editor.text")) }
                    .tag("text")
                    comparison
                        .padding(12)
                        .tabItem { Text(L10n.text("editor.compare")) }
                        .tag("compare")
                    versionView
                        .padding(12)
                        .tabItem { Text(L10n.text("editor.versions")) }
                        .tag("versions")
                    vocabularyView.padding(12)
                        .tabItem { Text(L10n.text("settings.cleanup.dictionary")) }.tag("vocabulary")
                    recleanupView.padding(12)
                        .tabItem { Text(L10n.text("editor.recleanup.title")) }.tag("recleanup")
                }
            } else {
                Spacer()
                Text(L10n.text("editor.unavailable_help")).foregroundColor(.secondary)
                Spacer()
            }
            Divider()
            HStack(spacing: 10) {
                if model.saving { ProgressView().controlSize(.small) }
                Text(L10n.text(model.candidate != nil ? "editor.recleanup.pending" : (model.hasChanges ? "editor.unsaved" : "editor.saved")))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(L10n.text("editor.copy_draft")) { model.copy(model.draft) }
                    .disabled(model.snapshot == nil)
                Button(L10n.text("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.saving)
                Button(L10n.text("common.save")) { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.saving || model.reviewingCleanup || !model.hasChanges || model.snapshot == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 500, idealHeight: 620)
        .interactiveDismissDisabled(model.saving)
        .onExitCommand { if !model.saving { dismiss() } }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.expireIfNeeded() }
        .onDisappear { model.stopComparison(); model.discardRecleanup() }
    }

    private var vocabularyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("editor.vocabulary.help")).font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("editor.vocabulary.term")).font(.caption).foregroundColor(.secondary)
                TextField("", text: $model.vocabularyTerm)
                    .accessibilityLabel(L10n.text("editor.vocabulary.term"))
                    .accessibilityIdentifier("historyVocabularyTerm")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("editor.vocabulary.variant")).font(.caption).foregroundColor(.secondary)
                TextField("", text: $model.vocabularyVariant)
                    .accessibilityLabel(L10n.text("editor.vocabulary.variant"))
                    .accessibilityIdentifier("historyVocabularyVariant")
            }
            Text(L10n.format("profiles.vocabulary_scope", model.vocabularyScopeLabel)).font(.caption).foregroundColor(.secondary)
            Text(L10n.text("editor.vocabulary.variant_help")).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("editor.vocabulary.confirm"), isOn: $model.vocabularyConfirmed)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.text("editor.vocabulary.save")) { model.saveVocabulary() }
                .disabled(model.saving || !model.vocabularyConfirmed || model.vocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.vocabularySaved {
                Label(L10n.text("editor.vocabulary.saved"), systemImage: "checkmark.circle").foregroundColor(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .disabled(model.saving)
    }

    private var recleanupView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("editor.recleanup.help")).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let candidate = model.candidate {
                ScrollView {
                    Text(verbatim: candidate.result.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("historyRecleanupCandidate")
                Text(L10n.text("editor.recleanup.replace_help")).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.text("common.copy")) { model.copy(candidate.result.text) }
                    Button(L10n.text("editor.recleanup.discard")) { model.discardRecleanup() }
                    Spacer()
                    Button(L10n.text("editor.recleanup.accept")) { model.acceptRecleanup() }
                }
                .disabled(model.saving)
            } else if model.recleaning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("editor.recleanup.running"))
                    Spacer()
                    Button(L10n.text("common.cancel")) { model.discardRecleanup() }
                }
                Spacer()
            } else {
                Button(L10n.text("editor.recleanup.start")) { model.startRecleanup() }
                    .disabled(model.saving)
                Spacer()
            }
        }
    }

    @ViewBuilder private var comparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("editor.compare_help")).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 16) {
                Label(L10n.text("editor.removed"), systemImage: "minus").foregroundColor(.red)
                Label(L10n.text("editor.added"), systemImage: "plus").foregroundColor(.green)
                Spacer()
                if model.comparing { ProgressView().controlSize(.small) }
            }
            if let difference = model.difference {
                ScrollView {
                    if difference.isSummarized {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("editor.summary")).font(.callout.bold())
                            readOnlySection(L10n.text("editor.raw"), difference.before)
                            readOnlySection(L10n.text("editor.draft"), difference.after)
                        }
                    } else {
                        Text(attributed(difference)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityIdentifier("historyCorrectionDifference")
            } else { Spacer() }
        }
    }

    private func attributed(_ result: TextDifference.Result) -> AttributedString {
        var text = AttributedString()
        for segment in result.segments {
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .unchanged: break
            case .removed: part.foregroundColor = .red; part.strikethroughStyle = .single
            case .added: part.foregroundColor = .green; part.underlineStyle = .single
            }
            text.append(part)
        }
        return text
    }

    private var versionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("editor.versions_help")).font(.caption).foregroundColor(.secondary)
            Picker(L10n.text("editor.version"), selection: $selectedVersion) {
                ForEach(versions) { version in Text(version.title).tag(version.id) }
            }
            .accessibilityIdentifier("historyCorrectionVersion")
            if let version = versions.first(where: { $0.id == selectedVersion }) {
                if let origin = version.origin { Text(L10n.text("editor.origin.\(origin.rawValue)")).font(.caption).foregroundColor(.secondary) }
                ScrollView {
                    Text(verbatim: version.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("historyCorrectionVersionText")
                HStack {
                    Spacer()
                    Button(L10n.text("editor.copy_version")) { model.copy(version.text) }
                }
            }
        }
    }

    private func readOnlySection(_ title: String, _ text: String) -> some View {
        GroupBox(title) {
            Text(verbatim: text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
    }
}
