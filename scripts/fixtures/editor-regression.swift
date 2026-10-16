import Foundation
import StillePostCore

@main
struct EditorRegression {
    @MainActor static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sp-editor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseDir: base)
        try store.append(.init(date: Date(timeIntervalSince1970: 1_790_000_000), rawText: "Rohtext Grüße 128", cleanText: "Ergebnis Grüße 128.", status: "ok", durationSec: 1))
        let snapshot = try store.list()[0]
        let editor = HistoryEditorModel(entry: snapshot, history: store)
        editor.draft = String(repeating: "Alter aufwendiger Entwurf. ", count: 1500)
        try await Task.sleep(nanoseconds: 160_000_000)
        editor.draft = "Neuester Entwurf Grüße 256!"
        let deadline = Date().addingTimeInterval(3)
        while editor.comparing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(editor.difference?.after == editor.draft, "Veralteter Vergleich überschreibt aktuellen Entwurf")
        let untouched = try store.list()[0]
        precondition(untouched.cleanText == snapshot.cleanText, "Entwurf wird ohne Save gespeichert")
        editor.save()
        await editor.saveTask?.value
        precondition(!editor.hasChanges && editor.snapshot?.manualEditCount == 1)
        let competing = HistoryEditorModel(entry: try store.list()[0], history: store)
        editor.draft = "Erste gespeicherte Änderung"
        editor.save(); await editor.saveTask?.value
        competing.draft = "Konkurrierender ungespeicherter Entwurf"
        competing.save(); await competing.saveTask?.value
        precondition(competing.errorMessage != nil && competing.hasChanges)
        precondition(competing.draft == "Konkurrierender ungespeicherter Entwurf")
        try await store.deleteAsync(id: snapshot.id)
        competing.reconcile(try await store.listAsync())
        precondition(competing.snapshot == nil && competing.draft.isEmpty && competing.difference == nil)
        var expiring = snapshot
        expiring.textExpiresAt = Date().addingTimeInterval(-1)
        let expired = HistoryEditorModel(entry: expiring, history: store)
        expired.save()
        precondition(expired.snapshot == nil && expired.draft.isEmpty)
        print("PASS asynchroner Vergleich, neuester Entwurf, Save, Konflikt, Löschung und Ablauf im echten Editor-Modell")
    }
}
