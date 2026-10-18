import CryptoKit
import XCTest
@testable import StillePostClientCore

final class LocalModelTests: XCTestCase {
    private let data = Data("A bounded artificial model fixture.".utf8)
    private let revision = String(repeating: "a", count: 40)

    private func catalog(path: String = "weights/model.bin") throws -> LocalModelCatalog {
        try LocalModelCatalog(model: "fixture", revision: revision, files: [LocalModelFile(path: path, size: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://huggingface.co/fixture/model/resolve/\(revision)/weights/model.bin")!)])
    }

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("stille-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    func testBundledCatalogPinsEveryFileAndExactDownloadSize() throws {
        let value = try LocalModelCatalog.bundled()
        XCTAssertEqual(value.totalBytes, 648_663_349)
        XCTAssertEqual(value.files.count, 25)
        XCTAssertEqual(value.revision, "0f63a7800b00dd0226abd051b906c246e1907482")
        XCTAssertTrue(value.files.contains { $0.path == "tokenizer/tokenizer.json" })
        XCTAssertThrowsError(try catalog(path: "../outside"))
        XCTAssertThrowsError(try catalog(path: "weights/model.bin.part"))
        let file = value.files[0]
        XCTAssertThrowsError(try LocalModelCatalog(model: "fixture", revision: revision, files: [file, file]))
    }

    func testInstallationPublishesOnlyAfterHashAndRestartsWithoutNetwork() async throws {
        let root = try directory(), descriptor = try catalog()
        let downloader = FixtureModelDownloader(data: data)
        let store = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        let initial = try await store.inventory()
        XCTAssertFalse(initial.installed); XCTAssertEqual(initial.downloadedBytes, 0)
        try await store.install(using: downloader) { _ in }
        let restarted = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        let installed = try await restarted.validateInstalled()
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent(descriptor.files[0].path)), data)
        let calls = await downloader.calls; XCTAssertEqual(calls, [0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Download").path))
    }

    func testInterruptedDownloadKeepsBoundedPartAndExplicitResumeAfterRestart() async throws {
        let root = try directory(), descriptor = try catalog()
        let first = FixtureModelDownloader(data: data, interruptAfter: 8)
        let store = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        do { try await store.install(using: first) { _ in }; XCTFail("Abbruch erwartet") }
        catch is CancellationError { }
        let partial = try await store.inventory()
        XCTAssertFalse(partial.installed); XCTAssertEqual(partial.downloadedBytes, 8)
        let resumed = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        let second = FixtureModelDownloader(data: data)
        try await resumed.install(using: second) { _ in }
        let calls = await second.calls; XCTAssertEqual(calls, [8])
        _ = try await resumed.validateInstalled()
    }

    func testCorruptDownloadIsNeverInstalledAndCanBeRetriedExplicitly() async throws {
        let root = try directory(), descriptor = try catalog()
        let store = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        do {
            try await store.install(using: FixtureModelDownloader(data: Data(repeating: 0, count: data.count))) { _ in }
            XCTFail("Hashfehler erwartet")
        } catch { XCTAssertEqual(error as? LocalModelFailure, .integrity) }
        let state = try await store.inventory(); XCTAssertFalse(state.installed); XCTAssertEqual(state.downloadedBytes, 0)
        try await store.install(using: FixtureModelDownloader(data: data)) { _ in }
        _ = try await store.validateInstalled()
    }

    func testInsufficientSpaceStopsBeforeNetworkAndPreservesExistingPart() async throws {
        let root = try directory(), descriptor = try catalog()
        let part = root.appendingPathComponent("Download/weights/model.bin.part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.prefix(8).write(to: part)
        let downloader = FixtureModelDownloader(data: data)
        let store = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in 0 })
        do { try await store.install(using: downloader) { _ in }; XCTFail("Kapazitätsfehler erwartet") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .insufficientSpace) }
        let calls = await downloader.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: part), data.prefix(8))
    }

    func testTamperingIsDetectedBeforeLoadAndDeleteOnlyTouchesModelFiles() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("Model")
        let audio = parent.appendingPathComponent("pending.m4a"); try data.write(to: audio)
        let descriptor = try catalog()
        let store = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        try await store.install(using: FixtureModelDownloader(data: data)) { _ in }
        try Data(repeating: 1, count: data.count).write(to: root.appendingPathComponent("Installed/weights/model.bin"))
        do { _ = try await store.validateInstalled(); XCTFail("Integritätsfehler erwartet") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .integrity) }
        try await store.remove()
        XCTAssertEqual(try Data(contentsOf: audio), data)
        let state = try await store.inventory(); XCTAssertFalse(state.hasFiles)
    }

    func testSymlinkInPartialDirectoryCannotOverwriteOutsideFile() async throws {
        let parent = try directory(), root = parent.appendingPathComponent("Model"), outside = parent.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Download"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("model.bin.part"); try data.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Download/weights"), withDestinationURL: outside)
        let store = try LocalModelStore(directory: root, catalog: catalog(), capacity: { _ in Int64.max })
        do { try await store.install(using: FixtureModelDownloader(data: data)) { _ in }; XCTFail("Symlink muss scheitern") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .storage) }
        XCTAssertEqual(try Data(contentsOf: sentinel), data)
    }

    func testUnexpectedDirectoryAtFilePathIsNotRemovedAsCorruptData() async throws {
        let root = try directory(), target = root.appendingPathComponent("Download/weights/model.bin")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("preserve.txt"); try data.write(to: sentinel)
        let store = try LocalModelStore(directory: root, catalog: catalog(), capacity: { _ in Int64.max })
        do { try await store.install(using: FixtureModelDownloader(data: data)) { _ in }; XCTFail("Verzeichnis muss erhalten bleiben") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .storage) }
        XCTAssertEqual(try Data(contentsOf: sentinel), data)
    }

    func testConcurrentDeleteAndInstallAreRejectedUntilDownloadCancellationFinishes() async throws {
        let root = try directory(), descriptor = try catalog()
        let downloader = SuspendedModelDownloader()
        let store = try LocalModelStore(directory: root, catalog: descriptor, capacity: { _ in Int64.max })
        let task = Task { try await store.install(using: downloader) { _ in } }
        for _ in 0..<200 {
            if await downloader.started { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await downloader.started; XCTAssertTrue(started)
        do { try await store.remove(); XCTFail("Aktiven Download nicht löschen") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .busy) }
        do { try await store.install(using: downloader) { _ in }; XCTFail("Kein zweiter Download") }
        catch { XCTAssertEqual(error as? LocalModelFailure, .busy) }
        task.cancel()
        do { try await task.value; XCTFail("Abbruch erwartet") } catch is CancellationError { }
        try await store.remove()
    }
}

private actor FixtureModelDownloader: LocalModelDownloading {
    let data: Data
    let interruptAfter: Int?
    private(set) var calls: [Int] = []
    init(data: Data, interruptAfter: Int? = nil) { self.data = data; self.interruptAfter = interruptAfter }
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let previous = (try? Data(contentsOf: destination)) ?? Data()
        calls.append(previous.count)
        var combined = previous
        combined.append(data.dropFirst(previous.count).prefix(interruptAfter ?? data.count))
        try combined.write(to: destination)
        progress(Int64(combined.count))
        if interruptAfter != nil { throw CancellationError() }
    }
}

private actor SuspendedModelDownloader: LocalModelDownloading {
    private(set) var started = false
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        started = true
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw CancellationError()
    }
}
