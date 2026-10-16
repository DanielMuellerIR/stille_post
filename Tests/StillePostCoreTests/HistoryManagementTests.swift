import XCTest
@testable import StillePostCore

final class HistoryManagementTests: XCTestCase {
    private func withStore(_ body: (HistoryStore, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sp-single-delete-\(UUID())")
        let store = HistoryStore(baseDir: base)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(store, base)
    }

    func testSingleDeletionPreservesOtherEntriesAndSharedAudio() throws {
        try withStore { store, base in
            let audio = store.newRecordingURL()
            try Data("artificial audio".utf8).write(to: audio)
            let first = HistoryStore.Entry(rawText: "eins", cleanText: "eins", status: "failed", audioFileName: audio.lastPathComponent, durationSec: 1)
            let second = HistoryStore.Entry(rawText: "zwei", cleanText: "zwei", status: "failed", audioFileName: audio.lastPathComponent, durationSec: 1)
            try store.append(first); try store.append(second)
            try store.delete(id: first.id)
            XCTAssertEqual(try HistoryStore(baseDir: base).list().map(\.id), [second.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
            try store.delete(id: first.id)
            try store.delete(id: second.id)
            XCTAssertTrue(try store.list().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    func testAudioDeletionFailureKeepsOnlyAReferenceAndRejectsLateRetryText() throws {
        try withStore { store, _ in
            let audio = store.newRecordingURL()
            try Data("artificial audio".utf8).write(to: audio)
            let entry = HistoryStore.Entry(rawText: "Zu löschen", cleanText: "Zu löschen", status: "failed", audioFileName: audio.lastPathComponent, durationSec: 1)
            try store.append(entry)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.recordingsDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.recordingsDir.path) }
            XCTAssertThrowsError(try store.delete(id: entry.id))
            let remaining = try XCTUnwrap(store.list().first)
            XCTAssertEqual(remaining.rawText, "")
            XCTAssertEqual(remaining.cleanText, "")
            XCTAssertEqual(remaining.audioFileName, audio.lastPathComponent)
            XCTAssertEqual(remaining.deletionPending, true)
            XCTAssertThrowsError(try store.update(entry))
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.recordingsDir.path)
            try store.delete(id: entry.id)
            XCTAssertTrue(try store.list().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        }
    }

    func testWriteFailuresNeverOrphanAudioOrRestoreDeletedText() throws {
        enum Expected: Error { case write }
        for failingWrite in [1, 2] {
            try withStore { working, base in
                let audio = working.newRecordingURL()
                try Data("artificial audio".utf8).write(to: audio)
                let entry = HistoryStore.Entry(rawText: "Text", cleanText: "Text", status: "failed", audioFileName: audio.lastPathComponent, durationSec: 1)
                try working.append(entry)
                var writes = 0
                let failing = HistoryStore(baseDir: base) { data, url in
                    writes += 1
                    if writes == failingWrite { throw Expected.write }
                    try data.write(to: url, options: .atomic)
                }
                XCTAssertThrowsError(try failing.delete(id: entry.id))
                let retained = try XCTUnwrap(working.list().first)
                XCTAssertEqual(retained.audioFileName, audio.lastPathComponent)
                if failingWrite == 1 {
                    XCTAssertEqual(retained.cleanText, "Text")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
                } else {
                    XCTAssertEqual(retained.cleanText, "")
                    XCTAssertEqual(retained.deletionPending, true)
                    XCTAssertThrowsError(try working.update(entry))
                }
            }
        }
    }

    func testLegacyDeletionRemnantsRejectRetryTextAfterReload() throws {
        try withStore { store, base in
            let legacy = HistoryStore.Entry(rawText: "", cleanText: "", status: "failed",
                errorMessage: L10n.text("core.history.audio_delete_pending", language: "en"),
                audioFileName: "old-recording.wav", durationSec: 1)
            XCTAssertNil(legacy.deletionPending)
            try store.append(legacy)
            var lateRetry = legacy
            lateRetry.status = "ok"
            lateRetry.rawText = "Nicht wiederherstellen"
            lateRetry.cleanText = "Nicht wiederherstellen"
            let fresh = HistoryStore(baseDir: base)
            XCTAssertThrowsError(try fresh.update(lateRetry))
            let remaining = try XCTUnwrap(fresh.list().first)
            XCTAssertTrue(remaining.isDeletionPending)
            XCTAssertEqual(remaining.cleanText, "")
        }
    }

    func testSingleDeletionRefusesExternalAudioAndKeepsOtherHistory() throws {
        try withStore { store, base in
            let protected = base.appendingPathComponent("outside.wav")
            try Data("protected fixture".utf8).write(to: protected)
            let unsafe = HistoryStore.Entry(rawText: "weg", cleanText: "weg", status: "failed", audioFileName: "../outside.wav", durationSec: 1)
            let other = HistoryStore.Entry(rawText: "bleibt", cleanText: "bleibt", status: "ok", durationSec: 1)
            try store.append(unsafe); try store.append(other)
            XCTAssertThrowsError(try store.delete(id: unsafe.id))
            XCTAssertEqual(try store.list().map(\.id), [other.id])
            XCTAssertEqual(try Data(contentsOf: protected), Data("protected fixture".utf8))
        }
    }

    func testSingleDeletionRemovesOnlyTheAudioLinkAndPreservesItsExternalTarget() throws {
        try withStore { store, base in
            let target = base.appendingPathComponent("protected.wav")
            let bytes = Data("unrelated artificial file".utf8)
            try bytes.write(to: target)
            let link = store.recordingsDir.appendingPathComponent("linked.wav")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let entry = HistoryStore.Entry(rawText: "weg", cleanText: "weg", status: "failed",
                audioFileName: link.lastPathComponent, durationSec: 1)
            try store.append(entry)
            try store.delete(id: entry.id)
            XCTAssertTrue(try store.list().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }

    func testRootAudioNameCannotDeleteTheRecordingsDirectory() throws {
        try withStore { store, _ in
            let protected = store.recordingsDir.appendingPathComponent("protected.wav")
            let bytes = Data("other recording".utf8)
            try bytes.write(to: protected)
            let malformed = HistoryStore.Entry(rawText: "weg", cleanText: "weg", status: "failed",
                audioFileName: "/", durationSec: 1)
            try store.append(malformed)
            XCTAssertNil(store.audioURL(for: malformed))
            XCTAssertThrowsError(try store.delete(id: malformed.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.recordingsDir.path))
            XCTAssertEqual(try Data(contentsOf: protected), bytes)
        }
    }

    func testDirectoryAudioReferenceCannotRecursivelyDeleteItsContents() throws {
        try withStore { store, _ in
            let directory = store.recordingsDir.appendingPathComponent("not-a-recording.wav")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let protected = directory.appendingPathComponent("protected.txt")
            let bytes = Data("unrelated artificial file".utf8)
            try bytes.write(to: protected)
            let entry = HistoryStore.Entry(rawText: "weg", cleanText: "weg", status: "failed",
                audioFileName: directory.lastPathComponent, durationSec: 1)
            try store.append(entry)
            XCTAssertThrowsError(try store.delete(id: entry.id))
            XCTAssertEqual(try Data(contentsOf: protected), bytes)
            let remaining = try XCTUnwrap(store.list().first)
            XCTAssertTrue(remaining.isDeletionPending)
            XCTAssertEqual(remaining.rawText, "")
        }
    }

    func testIndependentStoresKeepConcurrentAppendsDuringSingleDeletion() throws {
        try withStore { app, base in
            let selected = HistoryStore.Entry(rawText: "löschen", cleanText: "löschen", status: "ok", durationSec: 1)
            try app.append(selected)
            let lock = NSLock()
            var errors: [Error] = []
            DispatchQueue.concurrentPerform(iterations: 25) { index in
                do {
                    if index == 0 { try app.delete(id: selected.id) }
                    else {
                        try HistoryStore(baseDir: base).append(.init(rawText: "\(index)", cleanText: "\(index)", status: "ok", durationSec: 1))
                    }
                } catch { lock.lock(); errors.append(error); lock.unlock() }
            }
            XCTAssertTrue(errors.isEmpty)
            let fresh = try HistoryStore(baseDir: base).list()
            XCTAssertEqual(fresh.count, 24)
            XCTAssertFalse(fresh.contains(where: { $0.id == selected.id }))
        }
    }

    func testSearchCombinesRawResultStatusAndCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T12:00:00+01:00"))
        let today = calendar.startOfDay(for: now)
        let sixDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today))
        let sevenDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let entries = [now, sixDaysAgo, sevenDaysAgo, tomorrow].map {
            HistoryStore.Entry(date: $0, rawText: "Grüße vom RAG", cleanText: "128 Euro", status: "ok", durationSec: 1)
        }
        var query = HistoryQuery()
        query.text = "GRUSSE 128"
        query.status = .successful
        query.period = .lastSevenDays
        XCTAssertEqual(query.filter(entries, now: now, calendar: calendar).map(\.id), Array(entries.prefix(2)).map(\.id))
        query.period = .today
        XCTAssertEqual(query.filter(entries, now: now, calendar: calendar).map(\.id), [entries[0].id])
        query.text = "kein Treffer"
        XCTAssertTrue(query.filter(entries, now: now, calendar: calendar).isEmpty)
        query.text = ""
        query.status = .failed
        XCTAssertTrue(query.filter(entries, now: now, calendar: calendar).isEmpty)
        query.period = .all
        let failed = HistoryStore.Entry(date: now, rawText: "", cleanText: "", status: "failed", durationSec: 1)
        XCTAssertEqual(query.filter(entries + [failed], now: now, calendar: calendar).map(\.id), [failed.id])
    }
    func testRetryRejectsMissingAndDeletionPendingEntriesBeforeTranscribing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sp-retry-guard-\(UUID())")
        let history = HistoryStore(baseDir: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let pending = HistoryStore.Entry(rawText: "", cleanText: "", status: "failed",
            audioFileName: "pending.wav", durationSec: 1, deletionPending: true)
        try history.append(pending)
        let before = try Data(contentsOf: base.appendingPathComponent("history.json"))
        let transcriber = HistoryRetryTranscriber()
        let engine = retryEngine(history: history, transcriber: transcriber)
        for entry in [pending, HistoryStore.Entry(rawText: "alt", cleanText: "alt", status: "failed", durationSec: 1)] {
            do {
                _ = try await engine.retry(entry: entry)
                XCTFail("Ein gelöschter Auftrag darf nicht neu verarbeitet werden")
            } catch HistoryStore.PersistenceError.entryNoLongerExists {} catch { XCTFail("Unerwarteter Fehler: \(error)") }
        }
        XCTAssertEqual(transcriber.calls, 0)
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("history.json")), before)
    }

    func testDeletionDuringRetryCannotReturnOrRestoreText() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sp-retry-delete-\(UUID())")
        let history = HistoryStore(baseDir: base)
        defer { try? FileManager.default.removeItem(at: base) }
        let audio = history.newRecordingURL()
        try Data("artificial audio".utf8).write(to: audio)
        let entry = HistoryStore.Entry(rawText: "Teiltext", cleanText: "Teiltext", status: "failed",
            audioFileName: audio.lastPathComponent, durationSec: 1)
        try history.append(entry)
        let cleanup = HistoryRetryCleanup()
        cleanup.beforeResult = {
            do { try HistoryStore(baseDir: base).delete(id: entry.id) }
            catch { XCTFail("Die parallele Löschung muss gelingen: \(error)") }
        }
        let engine = retryEngine(history: history, transcriber: HistoryRetryTranscriber(), cleanup: cleanup)
        do {
            _ = try await engine.retry(entry: entry)
            XCTFail("Der ausdrücklich gelöschte Auftrag darf kein Ergebnis mehr zurückgeben")
        } catch HistoryStore.PersistenceError.entryNoLongerExists {} catch { XCTFail("Unerwarteter Fehler: \(error)") }
        XCTAssertTrue(try HistoryStore(baseDir: base).list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    private func retryEngine(history: HistoryStore, transcriber: HistoryRetryTranscriber,
                             cleanup: HistoryRetryCleanup = HistoryRetryCleanup()) -> DictationEngine {
        let dependencies = DictationDependencies(transcriber: transcriber, server: HistoryRetryServer(), cleanup: cleanup,
            makeRecorder: { _ in fatalError("im Retry unbenutzt") },
            makeSegmenter: { _ in fatalError("im Retry unbenutzt") },
            makeWavWriter: { _ in fatalError("im Retry unbenutzt") })
        return DictationEngine(config: Config(), history: history, dependencies: dependencies)
    }

}


private final class HistoryRetryTranscriber: DictationTranscriber {
    var calls = 0
    func transcribe(samples: [Float]) async throws -> String { calls += 1; return "Neuer Ergebnistext" }
    func transcribe(wavFile: URL) async throws -> String { calls += 1; return "Neuer Ergebnistext" }
    func isReachable() async -> Bool { true }
}

private final class HistoryRetryServer: DictationServer {
    func ensureRunning(reachability: any DictationTranscriber) async throws {}
    func stop() {}
}

private final class HistoryRetryCleanup: DictationCleanup {
    var onFallbackEndpoint: ((String) -> Void)?
    var onPrimaryRetry: (() -> Void)?
    var beforeResult: (() -> Void)?
    func clean(_ rawText: String) async -> CleanupService.Result {
        beforeResult?()
        return CleanupService.Result(text: rawText, usedFallback: false, fallbackReason: nil, endpoint: "test")
    }
    func warmUp() {}
}
