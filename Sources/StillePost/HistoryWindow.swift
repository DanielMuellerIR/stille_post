import AppKit
import SwiftUI
import StillePostCore

/// Fenster mit dem Diktat-Verlauf: ansehen, kopieren, fehlgeschlagene erneut
/// transkribieren, lokal suchen und gezielt löschen.
final class HistoryWindowController {

    private var window: NSWindow?
    private let model: HistoryViewModel

    init(engine: DictationEngine) {
        model = HistoryViewModel(engine: engine)
    }

    func reportError(_ message: String) { model.errorMessage = message }
    var pendingSaveTask: Task<Void, Never>? { model.editor?.saveTask }

    /// Öffnet das Fenster (oder holt es nach vorn) und lädt die Einträge neu.
    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.text("window.history.title")
            window.center()
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.contentView = NSHostingView(rootView: HistoryView(model: model))
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Schließt das Fenster (beim Neuaufbau nach Einstellungs-Änderungen — der
    /// Controller wird dann durch einen frischen mit der neuen Engine ersetzt).
    func close() {
        window?.close()
    }
}

/// Beobachtbares Modell fürs Verlaufsfenster.
final class HistoryViewModel: ObservableObject {
    @Published var entries: [HistoryStore.Entry] = []
    @Published var visibleEntries: [HistoryStore.Entry] = []
    @Published var query = HistoryQuery() { didSet { filterEntries() } }
    @Published var loading = false
    @Published var filtering = false
    @Published var deleting: Set<UUID> = []
    /// IDs der Einträge, bei denen gerade "Erneut transkribieren" läuft.
    @Published var retrying: Set<UUID> = []
    @Published var errorMessage: String?
    @Published var deletingAll = false
    @Published var editor: HistoryEditorModel?
    /// Nur das Ergebnis des neuesten Leseauftrags darf die Liste ersetzen.
    /// Zwei schnell aufeinanderfolgende Reloads können off-main andersherum
    /// fertig werden, obwohl beide korrekt gelesen haben.
    private var reloadGeneration: UInt64 = 0
    private var filterGeneration: UInt64 = 0
    private var filterWorker: Task<[HistoryStore.Entry], Never>?

    let engine: DictationEngine

    init(engine: DictationEngine) {
        self.engine = engine
        engine.history.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    deinit { filterWorker?.cancel() }

    func reload() {
        loading = true
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let history = engine.history
        Task { @MainActor [weak self] in
            let result: Result<[HistoryStore.Entry], Error>
            do { result = .success(try await history.listAsync()) }
            catch { result = .failure(error) }
            guard let self, generation == self.reloadGeneration else { return }
            self.loading = false
            switch result {
            case .success(let entries):
                self.entries = entries
                self.editor?.reconcile(entries)
                self.filterEntries()
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func filterEntries() {
        filterGeneration &+= 1
        let generation = filterGeneration
        let entries = entries
        let query = query
        filtering = true
        filterWorker?.cancel()
        let worker = Task.detached(priority: .userInitiated) { query.filter(entries) }
        filterWorker = worker
        Task { @MainActor [weak self] in
            let matches = await worker.value
            guard let self, generation == self.filterGeneration else { return }
            self.visibleEntries = matches
            self.filtering = false
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func edit(_ entry: HistoryStore.Entry) {
        guard entry.canEdit, !deletingAll, !deleting.contains(entry.id), !retrying.contains(entry.id) else { return }
        editor = HistoryEditorModel(entry: entry, history: engine.history)
    }

    func retry(_ entry: HistoryStore.Entry) {
        guard !deletingAll, !deleting.contains(entry.id), !retrying.contains(entry.id),
              !entry.isDeletionPending else { return }
        retrying.insert(entry.id)
        Task { @MainActor in
            do {
                _ = try await engine.retry(entry: entry)
            } catch {
                errorMessage = error.localizedDescription
            }
            retrying.remove(entry.id)
            reload()
        }
    }

    func delete(_ entry: HistoryStore.Entry) {
        guard !deletingAll, !retrying.contains(entry.id), !deleting.contains(entry.id) else { return }
        deleting.insert(entry.id)
        let history = engine.history
        Task { @MainActor [weak self] in
            defer { self?.deleting.remove(entry.id) }
            do {
                try await history.deleteAsync(id: entry.id)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.reload()
        }
    }

    func deleteAll() {
        guard !deletingAll, deleting.isEmpty, retrying.isEmpty else { return }
        deletingAll = true
        let history = engine.history
        Task { @MainActor [weak self] in
            defer { self?.deletingAll = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try history.deleteAll()
                }.value
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.reload()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var confirmDeleteAll = false
    @State private var selection: UUID?
    @State private var pendingDeletion: HistoryStore.Entry?
    @FocusState private var searchFocused: Bool

    private var selectedEntry: HistoryStore.Entry? {
        model.visibleEntries.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Button { searchFocused = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("history.search"))
                    .accessibilityLabel(L10n.text("history.search"))
                    .keyboardShortcut("f", modifiers: .command)
                    TextField(L10n.text("history.search"), text: $model.query.text)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .accessibilityIdentifier("historySearch")
                    if !model.query.text.isEmpty {
                        Button { model.query.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.text("history.clear_search"))
                    }
                }
                HStack(spacing: 14) {
                    Picker(L10n.text("history.period"), selection: $model.query.period) {
                        ForEach(HistoryQuery.Period.allCases, id: \.self) { period in
                            Text(L10n.text("history.period.\(period.rawValue)")).tag(period)
                        }
                    }
                    .accessibilityIdentifier("historyPeriod")
                    Picker(L10n.text("history.status"), selection: $model.query.status) {
                        ForEach(HistoryQuery.Status.allCases, id: \.self) { status in
                            Text(L10n.text("history.status.\(status.rawValue)")).tag(status)
                        }
                    }
                    .accessibilityIdentifier("historyStatus")
                }
                .pickerStyle(.menu)
            }
            .padding(14)
            Divider()
            if model.loading && model.entries.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if model.entries.isEmpty {
                Spacer()
                Text(L10n.text("history.empty"))
                    .foregroundColor(.secondary)
                Spacer()
            } else if model.visibleEntries.isEmpty {
                Spacer()
                Text(L10n.text("history.no_matches"))
                    .foregroundColor(.secondary)
                Button(L10n.text("history.reset_filters")) { model.query = HistoryQuery() }
                    .padding(.top, 6)
                Spacer()
            } else {
                List(model.visibleEntries, selection: $selection) { entry in
                    EntryRow(entry: entry, model: model)
                        .padding(.vertical, 4)
                        .tag(entry.id)
                        .contextMenu {
                            Button(L10n.text("history.delete_one"), role: .destructive) {
                                pendingDeletion = entry
                            }
                            .disabled(model.deletingAll || model.retrying.contains(entry.id) || model.deleting.contains(entry.id))
                        }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(L10n.format("history.match_count", model.visibleEntries.count, model.entries.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if model.loading || model.filtering || !model.deleting.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help(L10n.text("history.refresh"))
                    .accessibilityLabel(L10n.text("history.refresh"))
                    .keyboardShortcut("r", modifiers: .command)
                Button(L10n.text("history.delete_one"), role: .destructive) {
                    pendingDeletion = selectedEntry
                }
                .disabled(selectedEntry == nil || model.deletingAll ||
                    selectedEntry.map { model.retrying.contains($0.id) || model.deleting.contains($0.id) } == true)
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label(L10n.text("history.delete_all"), systemImage: "trash")
                }
                .disabled(model.entries.isEmpty || model.deletingAll || !model.deleting.isEmpty || !model.retrying.isEmpty)
                .confirmationDialog(L10n.text("history.delete_all.confirm"),
                                    isPresented: $confirmDeleteAll) {
                    Button(L10n.text("history.delete_all"), role: .destructive) { model.deleteAll() }
                    Button(L10n.text("common.cancel"), role: .cancel) {}
                } message: {
                    Text(L10n.text("history.delete_all.message"))
                }
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 400)
        .sheet(item: $model.editor) { editor in HistoryEditorView(model: editor) }
        .onChange(of: model.visibleEntries.map(\.id)) { ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .alert(L10n.text("history.delete_one.confirm"), isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { entry in
            Button(L10n.text("history.delete_one"), role: .destructive) {
                model.delete(entry)
                pendingDeletion = nil
            }
            Button(L10n.text("common.cancel"), role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text(L10n.text("history.delete_one.message"))
        }
        .alert(L10n.text("history.persistence_error"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L10n.text("common.ok")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Eine Zeile im Verlauf: Datum, Status, Text, Aktionen.
struct EntryRow: View {
    let entry: HistoryStore.Entry
    @ObservedObject var model: HistoryViewModel
    /// Zeigt zusätzlich den ROHEN Whisper-Text (vor der Bereinigung).
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.isFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(entry.isFailed ? .red : .green)
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(L10n.format("history.duration", entry.durationSec))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if entry.resultOrigin == .manual {
                    Text(L10n.text("editor.origin.manual"))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(4)
                } else if entry.cleanupFellBack == true {
                    // Kennzeichnung: Die LLM-Bereinigung wurde verworfen (Plausibilitäts-
                    // prüfung) — es wurde der rohe Whisper-Text verwendet. Der
                    // gespeicherte Grund beantwortet als Tooltip "warum eigentlich?".
                    Text(L10n.text("history.raw_fallback"))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                        .help(entry.cleanupFallbackReason ?? "")
                } else if let note = entry.cleanupFallbackReason {
                    // Teil-Rücksetzung: Bereinigung wurde verwendet, aber einzelne
                    // Satzteile kamen aus dem Rohtext (Worttreue-Prüfung).
                    Text(note)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.2))
                        .cornerRadius(4)
                }
                Spacer()

                if entry.isFailed {
                    if entry.canRetry {
                        if model.retrying.contains(entry.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L10n.text("history.retry")) { model.retry(entry) }
                                .font(.caption)
                                .disabled(model.deletingAll || model.deleting.contains(entry.id))
                        }
                    }
                } else {
                    Button(L10n.text("editor.edit")) { model.edit(entry) }
                        .font(.caption)
                        .disabled(!entry.canEdit || model.deletingAll || model.retrying.contains(entry.id) || model.deleting.contains(entry.id))
                    Button {
                        model.copyToClipboard(entry.cleanText)
                    } label: {
                        Label(L10n.text("history.copy"), systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                }
            }

            // Diagnose-Zeile: welcher Bereinigungs-Endpoint, wie lange? Beantwortet
            // "warum war dieses Diktat lahm?" direkt im Verlauf (Fallback sichtbar).
            if let endpoint = entry.cleanupEndpoint, let sec = entry.cleanupSec {
                Text(L10n.format(entry.resultOrigin == .manual ? "editor.original_cleaned_via" : "history.cleaned_via", sec, endpoint))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if entry.isFailed {
                Text(entry.diagnosticMessage ?? L10n.text("history.transcription_failed"))
                    .font(.callout)
                    .foregroundColor(.red)
                if entry.audioFileName != nil, entry.isAudioExpired {
                    Text(L10n.text("core.history.audio_expired")).font(.caption).foregroundColor(.secondary)
                }
            } else {
                Text(showRaw ? entry.rawText : entry.cleanText)
                    .font(.body)
                    .textSelection(.enabled)  // Text direkt markier- und kopierbar
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.rawText.isEmpty, entry.rawText != entry.cleanText {
                    Toggle(L10n.text("history.show_raw"), isOn: $showRaw)
                        .font(.caption2)
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"  // ISO-nah, eindeutig
        return formatter
    }()
}
