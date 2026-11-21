import XCTest
@testable import StillePost
import Foundation
import StillePostCore

final class HistoryEditorRegressionTests: XCTestCase {
    @MainActor func testConflictExpiryAndVocabularyUsePersistentHistory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sp-editor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let configURL = base.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let config = ConfigFile(url: configURL)
        try config.save(Config())
        let store = HistoryStore(baseDir: base)
        try store.append(.init(date: Date(timeIntervalSince1970: 1_790_000_000), rawText: "Rohtext Grüße 128", cleanText: "Ergebnis Grüße 128.", status: "ok", durationSec: 1))
        let snapshot = try store.list()[0]
        let editor = HistoryEditorModel(entry: snapshot, history: store, configFile: config)
        editor.vocabularyTerm = "Whisper"
        editor.vocabularyVariant = "Whis per"
        editor.saveVocabulary()
        let beforeConfirmation = try ConfigFile(url: configURL).load()
        XCTAssertTrue(beforeConfirmation.cleanup.dictionaryVariants.isEmpty, "Bestätigung fehlt")
        editor.vocabularyConfirmed = true
        editor.saveVocabulary(); await editor.saveTask?.value
        XCTAssertTrue(editor.vocabularySaved && !editor.vocabularyConfirmed)
        let afterConfirmation = try ConfigFile(url: configURL).load()
        XCTAssertTrue(afterConfirmation.cleanup.dictionaryVariants.count == 1)
        editor.vocabularyConfirmed = true
        editor.vocabularyVariant = "Whis per2"
        XCTAssertTrue(!editor.vocabularyConfirmed && !editor.vocabularySaved, "Eingabeänderung braucht erneute Bestätigung")
        editor.draft = String(repeating: "Alter aufwendiger Entwurf. ", count: 1500)
        try await Task.sleep(nanoseconds: 160_000_000)
        editor.draft = "Neuester Entwurf Grüße 256!"
        let deadline = Date().addingTimeInterval(3)
        while editor.comparing && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(editor.difference?.after == editor.draft, "Veralteter Vergleich überschreibt aktuellen Entwurf")
        let untouched = try store.list()[0]
        XCTAssertTrue(untouched.cleanText == snapshot.cleanText, "Entwurf wird ohne Save gespeichert")
        editor.save()
        await editor.saveTask?.value
        XCTAssertTrue(!editor.hasChanges && editor.snapshot?.manualEditCount == 1)
        let competing = HistoryEditorModel(entry: try store.list()[0], history: store, configFile: config)
        editor.draft = "Erste gespeicherte Änderung"
        editor.save(); await editor.saveTask?.value
        competing.draft = "Konkurrierender ungespeicherter Entwurf"
        competing.save(); await competing.saveTask?.value
        XCTAssertTrue(competing.errorMessage != nil && competing.hasChanges)
        XCTAssertTrue(competing.draft == "Konkurrierender ungespeicherter Entwurf")
        var copied: String?
        await competing.copy(competing.draft, write: { copied = $0 }).value
        XCTAssertTrue(copied == competing.draft, "Zulässiger Konfliktentwurf bleibt kopierbar")
        try await HistoryStore(baseDir: base).deleteAsync(id: snapshot.id)
        copied = nil
        await competing.copy(competing.draft, write: { copied = $0 }).value
        XCTAssertTrue(copied == nil, "Extern gelöschter Text darf nicht kopiert werden")
        XCTAssertTrue(competing.snapshot == nil && competing.draft.isEmpty && competing.difference == nil)
        XCTAssertTrue(competing.vocabularyTerm.isEmpty && competing.vocabularyVariant.isEmpty && competing.candidate == nil)
        var expiring = snapshot
        expiring.textExpiresAt = Date().addingTimeInterval(-1)
        let expired = HistoryEditorModel(entry: expiring, history: store, configFile: config)
        expired.save()
        XCTAssertTrue(expired.snapshot == nil && expired.draft.isEmpty)

    }
}
