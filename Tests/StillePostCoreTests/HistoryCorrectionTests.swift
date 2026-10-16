import XCTest
@testable import StillePostCore

final class HistoryCorrectionTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("sp-correction-\(UUID())") }
    private func entry() -> HistoryStore.Entry {
        .init(date: Date(timeIntervalSince1970: 1_790_000_000), rawText: "Grüße  128, Euro.\nCafe\u{301}", cleanText: "Grüße, 128 Euro.\nCafé", status: "ok", durationSec: 1, cleanupFellBack: true)
    }

    func testSavesPreserveRawBytesOriginalOutputAndOnlyThreePreviousVersions() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseDir: base)
        let original = entry()
        try store.append(original)
        var current = try XCTUnwrap(store.list().first)
        for number in 1...5 { current = try await store.saveCorrectionAsync("Manuell \(number) — Grüße!", expected: current) }
        let reopened = try XCTUnwrap(HistoryStore(baseDir: base).list().first)
        XCTAssertTrue(reopened.rawText.utf8.elementsEqual(original.rawText.utf8))
        XCTAssertEqual(reopened.originalCleanText, original.cleanText)
        XCTAssertEqual(reopened.originalResultOrigin, .rawFallback)
        XCTAssertEqual(reopened.resultOrigin, .manual)
        XCTAssertEqual(reopened.manualEditCount, 5)
        XCTAssertNotNil(reopened.manualEditDate)
        XCTAssertEqual(reopened.previousResults?.map(\.text), ["Manuell 4 — Grüße!", "Manuell 3 — Grüße!", "Manuell 2 — Grüße!"])
        let unchanged = try await store.saveCorrectionAsync(reopened.cleanText, expected: reopened)
        XCTAssertEqual(unchanged.manualEditCount, 5)
    }

    func testUnicodeNormalizationIsARealCorrectionAndStaleSnapshotConflicts() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseDir: base)
        try store.append(entry())
        let old = try XCTUnwrap(store.list().first)
        let nfd = old.cleanText.decomposedStringWithCanonicalMapping
        XCTAssertEqual(nfd, old.cleanText)
        let saved = try await store.saveCorrectionAsync(nfd, expected: old)
        XCTAssertEqual(saved.manualEditCount, 1)
        XCTAssertTrue(saved.cleanText.utf8.elementsEqual(nfd.utf8))
        do { _ = try await store.saveCorrectionAsync("Veralteter Entwurf", expected: old); XCTFail("Konflikt fehlt") }
        catch { XCTAssertEqual(error as? HistoryStore.PersistenceError, .correctionConflict) }
    }

    func testCompetingStoresCannotOverwriteEachOthersCorrection() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let first = HistoryStore(baseDir: base), second = HistoryStore(baseDir: base)
        try first.append(entry())
        let snapshot = try XCTUnwrap(first.list().first)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for (store, text) in [(first, "Erster Entwurf"), (second, "Zweiter Entwurf")] {
                group.addTask {
                    do { _ = try await store.saveCorrectionAsync(text, expected: snapshot); return true }
                    catch { return false }
                }
            }
            var result: [Bool] = []
            for await outcome in group { result.append(outcome) }
            return result
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(try first.list().first?.manualEditCount, 1)
    }

    func testLatePipelineUpdatePreservesCorrectionAndOnlyUpdatesAudio() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(baseDir: base)
        var pipeline = entry(); pipeline.audioFileName = "fixture.wav"
        try store.append(pipeline)
        let snapshot = try XCTUnwrap(store.list().first)
        let manual = try await store.saveCorrectionAsync("Bestätigte manuelle Fassung", expected: snapshot)
        pipeline.cleanText = "Verspätetes Pipeline-Ergebnis"
        pipeline.audioFileName = nil
        let receipt = try store.update(pipeline)
        XCTAssertEqual(receipt.cleanText, manual.cleanText)
        XCTAssertEqual(receipt.previousResults, manual.previousResults)
        XCTAssertEqual(receipt.originalCleanText, manual.originalCleanText)
        XCTAssertNil(receipt.audioFileName)
        pipeline.audioFileName = "fixture.wav"
        XCTAssertThrowsError(try store.update(pipeline)) { XCTAssertEqual($0 as? HistoryStore.PersistenceError, .correctionConflict) }
        pipeline.audioFileName = nil
        pipeline.rawText = "Anderer Rohtext"
        XCTAssertThrowsError(try store.update(pipeline)) { XCTAssertEqual($0 as? HistoryStore.PersistenceError, .correctionConflict) }
    }

    func testFailedAtomicCorrectionWritePreservesPreviousDiskState() async throws {
        let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
        let initial = HistoryStore(baseDir: base)
        try initial.append(entry())
        let expected = try XCTUnwrap(initial.list().first)
        let failing = HistoryStore(baseDir: base) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        do { _ = try await failing.saveCorrectionAsync("Nicht gespeichert", expected: expected); XCTFail("Schreibfehler fehlt") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        XCTAssertEqual(try initial.list().first, expected)
    }

    func testDeletedExpiredPrivateAndFailedEntriesCannotBeEdited() async throws {
        for scenario in ["deleted", "expired", "private", "failed"] {
            let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
            let store = HistoryStore(baseDir: base)
            var candidate = entry(); candidate.audioFileName = "fixture.wav"
            if scenario == "expired" { candidate.textExpiresAt = Date().addingTimeInterval(0.2) }
            if scenario == "private" { candidate.storesText = false }
            if scenario == "failed" { candidate.status = "failed" }
            try store.append(candidate)
            let snapshot = try XCTUnwrap(store.list().first)
            if scenario == "deleted" { try store.delete(id: snapshot.id) }
            if scenario == "expired" { try await Task.sleep(nanoseconds: 250_000_000) }
            do { _ = try await store.saveCorrectionAsync("Darf nicht bleiben", expected: snapshot); XCTFail(scenario) }
            catch { XCTAssertTrue(error is HistoryStore.PersistenceError, scenario) }
            XCTAssertFalse(String(decoding: try Data(contentsOf: base.appendingPathComponent("history.json")), as: UTF8.self).contains("Darf nicht bleiben"))
        }
    }

    func testEveryPrivacyAndDeletionPathRemovesAllRevisionText() async throws {
        for scenario in ["private-append", "private-update", "expiry", "discard", "delete", "delete-all"] {
            let base = directory(); defer { try? FileManager.default.removeItem(at: base) }
            let store = HistoryStore(baseDir: base)
            var candidate = entry()
            candidate.rawText = "RAW-MARKER"; candidate.cleanText = "CLEAN-MARKER"
            candidate.originalCleanText = "ORIGINAL-MARKER"
            candidate.manualEditCount = 2
            candidate.previousResults = [.init(text: "REVISION-MARKER", date: candidate.date, origin: .manual)]
            candidate.audioFileName = "fixture.wav"
            try Data([1]).write(to: store.recordingsDir.appendingPathComponent("fixture.wav"))
            if scenario == "private-append" { candidate.storesText = false }
            try store.append(candidate)
            switch scenario {
            case "private-update": candidate.storesText = false; try store.update(candidate)
            case "expiry":
                candidate.textExpiresAt = Date().addingTimeInterval(-1); try store.update(candidate)
            case "discard": try await store.discardAsync(candidate)
            case "delete", "delete-all":
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.recordingsDir.path)
                defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.recordingsDir.path) }
                if scenario == "delete" { XCTAssertThrowsError(try store.delete(id: candidate.id)) }
                else { XCTAssertThrowsError(try store.deleteAll()) }
            default: break
            }
            let json = String(decoding: try Data(contentsOf: base.appendingPathComponent("history.json")), as: UTF8.self)
            for marker in ["RAW-MARKER", "CLEAN-MARKER", "ORIGINAL-MARKER", "REVISION-MARKER"] { XCTAssertFalse(json.contains(marker), "\(scenario): \(marker)") }
        }
    }
}
