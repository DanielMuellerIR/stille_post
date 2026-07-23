import AppKit
import SwiftUI
import StillePostCore

/// Fenster mit dem Diktat-Verlauf: ansehen, kopieren, fehlgeschlagene erneut
/// transkribieren, alles löschen.
final class HistoryWindowController {

    private var window: NSWindow?
    private let model: HistoryViewModel

    init(engine: DictationEngine) {
        model = HistoryViewModel(engine: engine)
    }

    /// Öffnet das Fenster (oder holt es nach vorn) und lädt die Einträge neu.
    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.text("window.history.title")
            window.center()
            window.isReleasedWhenClosed = false
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
    /// IDs der Einträge, bei denen gerade "Erneut transkribieren" läuft.
    @Published var retrying: Set<UUID> = []
    @Published var errorMessage: String?

    let engine: DictationEngine

    init(engine: DictationEngine) {
        self.engine = engine
        engine.history.onChange = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    func reload() {
        do {
            entries = try engine.history.list()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func retry(_ entry: HistoryStore.Entry) {
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

    func deleteAll() {
        do {
            try engine.history.deleteAll()
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @State private var confirmDeleteAll = false

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                Spacer()
                Text(L10n.text("history.empty"))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(model.entries) { entry in
                    EntryRow(entry: entry, model: model)
                        .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(L10n.format(
                    model.entries.count == 1 ? "history.entry_count.one" : "history.entry_count.other",
                    model.entries.count
                ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(role: .destructive) {
                    confirmDeleteAll = true
                } label: {
                    Label(L10n.text("history.delete_all"), systemImage: "trash")
                }
                .disabled(model.entries.isEmpty)
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
        .frame(minWidth: 480, minHeight: 320)
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
                if entry.cleanupFellBack == true {
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
                    if model.retrying.contains(entry.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.text("history.retry")) { model.retry(entry) }
                            .font(.caption)
                    }
                } else {
                    Button {
                        model.copyToClipboard(showRaw ? entry.rawText : entry.cleanText)
                    } label: {
                        Label(L10n.text("history.copy"), systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                }
            }

            // Diagnose-Zeile: welcher Bereinigungs-Endpoint, wie lange? Beantwortet
            // "warum war dieses Diktat lahm?" direkt im Verlauf (Fallback sichtbar).
            if let endpoint = entry.cleanupEndpoint, let sec = entry.cleanupSec {
                Text(L10n.format("history.cleaned_via", sec, endpoint))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if entry.isFailed {
                Text(entry.errorMessage ?? L10n.text("history.transcription_failed"))
                    .font(.callout)
                    .foregroundColor(.red)
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
