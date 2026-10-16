import XCTest
@testable import StillePostCore

final class HistoryPrivacyTests: XCTestCase {
    private let marker = "PRIVACY-ARTIFICIAL-TRANSCRIPT-128"

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sp-privacy-\(UUID())")
    }

    private func audioEntry(_ history: HistoryStore, text: String) throws -> HistoryStore.Entry {
        let audio = history.newRecordingURL()
        try Data("RIFF artificial recording".utf8).write(to: audio)
        return HistoryStore.Entry(rawText: text, cleanText: text, status: "failed", errorMessage: text,
            audioFileName: audio.lastPathComponent, durationSec: 1,
            cleanupFallbackReason: text, cleanupEndpoint: text)
    }

    func testMigrationDefaultsAndMalformedPrivacyChoices() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertTrue(old.history.storeText)
        XCTAssertEqual(old.history.textRetentionDays, 0)
        XCTAssertEqual(old.history.audioRetentionDays, 0)
        for json in [#"{"history":"invalid"}"#, #"{"history":{"storeText":"invalid"}}"#] {
            XCTAssertFalse(try JSONDecoder().decode(Config.self, from: Data(json.utf8)).history.storeText)
        }
        let malformed = try JSONDecoder().decode(Config.self,
            from: Data(#"{"history":{"textRetentionDays":"invalid","audioRetentionDays":-1}}"#.utf8))
        XCTAssertEqual(malformed.history.textRetentionDays, 1)
        XCTAssertEqual(malformed.history.audioRetentionDays, 0)
        var config = old
        config.history.textRetentionDays = -1
        XCTAssertThrowsError(try config.validate())
    }

    func testFirstPrivateWriteNeverContainsTextOrFreeDiagnostics() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        var writes: [Data] = []
        let history = HistoryStore(baseDir: base) { data, url in
            writes.append(data)
            try data.write(to: url, options: .atomic)
        }
        var entry = try audioEntry(history, text: marker)
        entry.storesText = false
        let receipt = try history.append(entry)
        XCTAssertEqual(receipt.cleanText, marker, "Ausgabetext darf im RAM bleiben")
        XCTAssertTrue(receipt.isTextPrivate)
        XCTAssertFalse(writes.isEmpty)
        XCTAssertTrue(writes.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(marker) })
        let retained = try XCTUnwrap(HistoryStore(baseDir: base).list().first)
        XCTAssertEqual(retained.rawText, "")
        XCTAssertEqual(retained.cleanText, "")
        XCTAssertNil(retained.errorMessage)
        XCTAssertNil(retained.cleanupFallbackReason)
        XCTAssertNil(retained.cleanupEndpoint)
        XCTAssertTrue(retained.canRetry)
        XCTAssertFalse(retained.isDeletionPending)
        XCTAssertEqual(retained.diagnosticMessage, L10n.text("core.history.private_audio"))
        var expired = retained
        expired.audioExpiresAt = Date().addingTimeInterval(-1)
        XCTAssertFalse(expired.canRetry)
        XCTAssertEqual(expired.diagnosticMessage, L10n.text("core.history.private_audio_expired"))
    }

    func testTextDeadlineKeepsAudioAndLegacyEntriesAtExactBoundary() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let history = HistoryStore(baseDir: base)
        let deadline = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
        var audio = try audioEntry(history, text: marker)
        audio.textExpiresAt = deadline
        let textOnly = HistoryStore.Entry(rawText: marker, cleanText: marker, status: "ok", durationSec: 1,
                                         textExpiresAt: deadline)
        let legacy = HistoryStore.Entry(date: Date(timeIntervalSince1970: 100), rawText: "Altdaten", cleanText: "Altdaten", status: "ok", durationSec: 1)
        try history.append(audio); try history.append(textOnly); try history.append(legacy)
        try await history.applyRetentionAsync(now: deadline.addingTimeInterval(-1))
        XCTAssertEqual(try history.list().count, 3)
        try await history.applyRetentionAsync(now: deadline)
        let entries = try HistoryStore(baseDir: base).list()
        XCTAssertEqual(Set(entries.map(\.id)), Set([audio.id, legacy.id]))
        let retained = try XCTUnwrap(entries.first { $0.id == audio.id })
        XCTAssertTrue(retained.isTextPrivate)
        XCTAssertEqual(retained.cleanText, "")
        XCTAssertTrue(retained.canRetry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(history.audioURL(for: retained)).path))
        XCTAssertEqual(entries.first { $0.id == legacy.id }?.cleanText, "Altdaten")
    }

    func testAudioDeadlinePreservesTextAndSharedRecordingsAndRejectsLateReference() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let history = HistoryStore(baseDir: base)
        var expired = try audioEntry(history, text: marker)
        expired.audioExpiresAt = Date().addingTimeInterval(-10)
        let shared = HistoryStore.Entry(rawText: "Anderer Text", cleanText: "Anderer Text", status: "failed",
            audioFileName: expired.audioFileName, durationSec: 1)
        let noAudio = HistoryStore.Entry(rawText: "Erfolg", cleanText: "Erfolg", status: "ok", durationSec: 1,
                                        audioExpiresAt: expired.audioExpiresAt)
        try history.append(expired); try history.append(shared); try history.append(noAudio)
        let audio = try XCTUnwrap(history.audioURL(for: expired))
        try await history.applyRetentionAsync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let first = try XCTUnwrap(history.list().first { $0.id == expired.id })
        XCTAssertNil(first.audioFileName)
        XCTAssertEqual(first.cleanText, marker)
        XCTAssertNotNil(try history.list().first { $0.id == noAudio.id })
        XCTAssertThrowsError(try HistoryStore(baseDir: base).update(expired))
        var last = shared
        last.audioExpiresAt = Date().addingTimeInterval(-1)
        try history.update(last)
        try await history.applyRetentionAsync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try history.list().count, 3)
        XCTAssertTrue(try history.list().allSatisfy { $0.audioFileName == nil })
    }

    func testRetentionFailuresPreserveReachableAudioAndNeverClaimErasure() async throws {
        enum Expected: Error { case write }
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let working = HistoryStore(baseDir: base)
        var entry = try audioEntry(working, text: marker)
        entry.textExpiresAt = Date().addingTimeInterval(3600)
        try working.append(entry)
        let before = try Data(contentsOf: base.appendingPathComponent("history.json"))
        let failing = HistoryStore(baseDir: base) { _, _ in throw Expected.write }
        do { try await failing.applyRetentionAsync(now: try XCTUnwrap(entry.textExpiresAt)); XCTFail("Write muss scheitern") }
        catch Expected.write {} catch { XCTFail("Unerwarteter Fehler: \(error)") }
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("history.json")), before)
        entry.audioExpiresAt = Date().addingTimeInterval(-1)
        try working.update(entry)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: working.recordingsDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: working.recordingsDir.path) }
        do { try await working.applyRetentionAsync(); XCTFail("Unlink muss scheitern") } catch {}
        let retained = try XCTUnwrap(working.list().first)
        XCTAssertNotNil(retained.audioFileName)
        XCTAssertEqual(retained.cleanText, marker)
        XCTAssertFalse(retained.canRetry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(working.audioURL(for: retained)).path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: working.recordingsDir.path)
        try await working.applyRetentionAsync()
        XCTAssertNil(try working.list().first?.audioFileName)
    }

    func testFreshPrivatePolicyWinsAgainstConcurrentStaleUpdates() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let history = HistoryStore(baseDir: base)
        let original = try audioEntry(history, text: marker)
        try history.append(original)
        var privateEntry = original
        privateEntry.storesText = false
        try HistoryStore(baseDir: base).update(privateEntry)
        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { try HistoryStore(baseDir: base).update(original) }
            catch { lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertTrue(try XCTUnwrap(history.list().first).isTextPrivate)
        XCTAssertFalse(String(decoding: try Data(contentsOf: base.appendingPathComponent("history.json")), as: UTF8.self).contains(marker))
    }

    @MainActor
    func testPrivateSuccessIsTextFreeFromFirstWriteAndDeletesItsAudio() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let lock = NSLock()
        var snapshots: [Data] = []
        let history = HistoryStore(baseDir: base) { data, url in
            lock.withLock { snapshots.append(data) }
            try data.write(to: url, options: .atomic)
        }
        let entry = try audioEntry(history, text: marker)
        let audio = try XCTUnwrap(history.audioURL(for: entry))
        var config = Config(); config.history.storeText = false
        let engine = DictationEngine(config: config, history: history) { text in
            CleanupService.Result(text: text, usedFallback: false, fallbackReason: nil, endpoint: nil)
        }
        let delivered = expectation(description: "Privater Text ausgegeben")
        engine.onResult = { result in
            XCTAssertEqual(result.text, self.marker)
            XCTAssertTrue(result.entry?.isTextPrivate == true)
            delivered.fulfill()
        }
        engine.processForTesting(rawText: marker, wavURL: audio)
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertTrue(try history.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let saved = lock.withLock { snapshots }
        XCTAssertGreaterThanOrEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(marker) })
    }

    func testPrivateRetryEmitsOnlyTransientTextIncludingOnAudioDeletionFailure() async throws {
        for unlinkFails in [false, true] {
            let base = directory()
            let history = HistoryStore(baseDir: base)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: history.recordingsDir.path)
                try? FileManager.default.removeItem(at: base)
            }
            var entry = try audioEntry(history, text: marker)
            entry.storesText = false
            try history.append(entry)
            if unlinkFails { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: history.recordingsDir.path) }
            let engine = retryEngine(history: history)
            let emitted = expectation(description: "Nur flüchtiger Retry-Text")
            engine.onPrivateRetryResult = { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(result.cleanText, self.marker)
                XCTAssertTrue(result.isTextPrivate)
                emitted.fulfill()
            }
            do { _ = try await engine.retry(entry: entry); XCTAssertFalse(unlinkFails) }
            catch { XCTAssertTrue(unlinkFails, "Unerwarteter Fehler: \(error)") }
            await fulfillment(of: [emitted], timeout: 2)
            let stored = try history.list()
            XCTAssertEqual(stored.count, unlinkFails ? 1 : 0)
            XCTAssertTrue(stored.allSatisfy { $0.rawText.isEmpty && $0.cleanText.isEmpty && $0.isTextPrivate })
            XCTAssertFalse(String(decoding: try Data(contentsOf: base.appendingPathComponent("history.json")), as: UTF8.self).contains(marker))
        }
    }

    @MainActor
    func testPolicyChangeDoesNotAlterActiveProcessing() async throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let history = HistoryStore(baseDir: base)
        let gate = PrivacyGate()
        let started = expectation(description: "Bereinigung begonnen")
        var calls = 0
        let engine = DictationEngine(config: Config(), history: history) { text in
            calls += 1
            if calls == 1 { started.fulfill(); await gate.wait() }
            return CleanupService.Result(text: text, usedFallback: false, fallbackReason: nil, endpoint: nil)
        }
        let first = expectation(description: "Alter Auftrag fertig")
        engine.onResult = { _ in first.fulfill() }
        engine.processForTesting(rawText: "Alter Auftrag")
        await fulfillment(of: [started], timeout: 2)
        var policy = Config.History(); policy.storeText = false
        engine.configureHistory(policy)
        await gate.release()
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(try history.list().first?.cleanText, "Alter Auftrag")
        let second = expectation(description: "Neuer privater Auftrag fertig")
        engine.onResult = { result in XCTAssertTrue(result.entry?.isTextPrivate == true); second.fulfill() }
        engine.processForTesting(rawText: marker)
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(try history.list().count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: base.appendingPathComponent("history.json")), as: UTF8.self).contains(marker))
    }

    func testPolicyUsesCalendarDaysAcrossTimeChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z"))
        let entry = HistoryStore.Entry(date: date, rawText: "Test", cleanText: "Test", status: "ok", durationSec: 1)
        var policy = Config.History(); policy.textRetentionDays = 1
        let applied = policy.applying(to: entry, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(applied.textExpiresAt).timeIntervalSince(date), 25 * 3600)
        XCTAssertNil(applied.audioExpiresAt)
    }

    func testAudioRemovalWriteFailureKeepsReferenceUntilSuccessfulRetryOfMaintenance() async throws {
        enum Expected: Error { case write }
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let working = HistoryStore(baseDir: base)
        var entry = try audioEntry(working, text: marker)
        entry.storesText = false
        entry.audioExpiresAt = Date().addingTimeInterval(-1)
        try working.append(entry)
        let audio = try XCTUnwrap(working.audioURL(for: entry))
        let failing = HistoryStore(baseDir: base) { _, _ in throw Expected.write }
        do { try await failing.applyRetentionAsync(); XCTFail("Abschluss-Write muss scheitern") }
        catch Expected.write {} catch { XCTFail("Unerwarteter Fehler: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try working.list().first?.audioFileName, entry.audioFileName)
        XCTAssertFalse(String(decoding: try Data(contentsOf: base.appendingPathComponent("history.json")), as: UTF8.self).contains(marker))
        try await working.applyRetentionAsync()
        XCTAssertTrue(try working.list().isEmpty)
    }

    func testRetryStartsOnlyNewTextDeadlineAndDoesNotRetrofitAudioDeadline() async throws {
        let base = directory()
        let history = HistoryStore(baseDir: base)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: history.recordingsDir.path)
            try? FileManager.default.removeItem(at: base)
        }
        var entry = try audioEntry(history, text: "Alter Teiltext")
        entry.date = Date(timeIntervalSince1970: 100)
        try history.append(entry)
        var config = Config()
        config.history.textRetentionDays = 1
        config.history.audioRetentionDays = 7
        let engine = retryEngine(history: history, config: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: history.recordingsDir.path)
        do { _ = try await engine.retry(entry: entry); XCTFail("Unlink muss scheitern") } catch {}
        let stored = try XCTUnwrap(history.list().first)
        XCTAssertEqual(stored.cleanText, marker)
        XCTAssertGreaterThan(try XCTUnwrap(stored.textExpiresAt), Date())
        XCTAssertNil(stored.audioExpiresAt, "Eine alte Aufnahme erhält keine nachträgliche Audiofrist")
        XCTAssertEqual(stored.date, entry.date)
    }

    private func retryEngine(history: HistoryStore, config: Config = Config()) -> DictationEngine {
        let dependencies = DictationDependencies(transcriber: PrivacyTranscriber(text: marker), server: PrivacyServer(),
            cleanup: PrivacyCleanup(), makeRecorder: { _ in fatalError("im Retry unbenutzt") },
            makeSegmenter: { _ in fatalError("im Retry unbenutzt") }, makeWavWriter: { _ in fatalError("im Retry unbenutzt") })
        return DictationEngine(config: config, history: history, dependencies: dependencies)
    }
}

private actor PrivacyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class PrivacyTranscriber: DictationTranscriber {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(samples: [Float]) async throws -> String { text }
    func transcribe(wavFile: URL) async throws -> String { text }
    func isReachable() async -> Bool { true }
}
private final class PrivacyServer: DictationServer {
    func ensureRunning(reachability: any DictationTranscriber) async throws {}
    func stop() {}
}
private final class PrivacyCleanup: DictationCleanup {
    var onFallbackEndpoint: ((String) -> Void)?
    var onPrimaryRetry: (() -> Void)?
    func clean(_ text: String) async -> CleanupService.Result {
        CleanupService.Result(text: text, usedFallback: false, fallbackReason: nil, endpoint: nil)
    }
    func warmUp() {}
}
