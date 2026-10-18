import CryptoKit
import XCTest
@testable import StillePostClientCore

@MainActor final class LocalModelSessionTests: XCTestCase {
    private func session(adapter: ControlledModelAdapter) async throws -> LocalModelSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-lifecycle-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let data = Data("synthetic model".utf8), revision = String(repeating: "a", count: 40)
        let catalog = try LocalModelCatalog(model: "fixture", revision: revision, files: [LocalModelFile(path: "model.bin", size: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://huggingface.co/fixture/model/resolve/\(revision)/model.bin")!)])
        let store = try LocalModelStore(directory: directory, catalog: catalog, capacity: { _ in Int64.max })
        try await store.install(using: SessionModelDownloader(data: data)) { _ in }
        let session = LocalModelSession(store: store, totalBytes: catalog.totalBytes, adapter: adapter)
        session.refresh()
        try await wait { session.state.phase == .available }
        return session
    }

    func testBackgroundDuringNativeLoadWaitsThenUnloadsAndRejectsSecondLoad() async throws {
        let adapter = ControlledModelAdapter(), session = try await session(adapter: adapter)
        session.load()
        try await wait { await adapter.loading }
        session.interrupt(.background)
        XCTAssertEqual(session.state.phase, .stopping)
        session.load(); session.remove()
        let loads = await adapter.loads, unloads = await adapter.unloads
        XCTAssertEqual(loads, 1); XCTAssertEqual(unloads, 0)
        await adapter.finishLoading()
        try await wait { session.state.phase == .available }
        let releases = await adapter.unloads; XCTAssertEqual(releases, 1)
        XCTAssertEqual(session.state.notice, .background)
        XCTAssertTrue(session.state.installed)
        XCTAssertNotEqual(session.state.phase, .loaded)
    }

    func testMemoryWarningReleasesLoadedModelWithoutRemovingFilesOrReloading() async throws {
        let adapter = ControlledModelAdapter(), session = try await session(adapter: adapter)
        session.load(); try await wait { await adapter.loading }
        await adapter.finishLoading()
        try await wait { session.state.phase == .loaded }
        session.interrupt(.memory)
        try await wait { session.state.phase == .available }
        XCTAssertTrue(session.state.installed); XCTAssertEqual(session.state.notice, .memory)
        session.refresh(); try await wait { session.state.phase == .available }
        let loads = await adapter.loads, unloads = await adapter.unloads
        XCTAssertEqual(loads, 1); XCTAssertEqual(unloads, 1)
    }

    func testExplicitRemoveUnloadsBeforeDeletingInstalledModel() async throws {
        let adapter = ControlledModelAdapter(), session = try await session(adapter: adapter)
        session.load(); try await wait { await adapter.loading }; await adapter.finishLoading()
        try await wait { session.state.phase == .loaded }
        session.remove(); try await wait { session.state.phase == .missing }
        XCTAssertFalse(session.state.installed)
        let unloads = await adapter.unloads; XCTAssertEqual(unloads, 1)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Erwarteter Modellzustand fehlt")
        throw LocalModelFailure.busy
    }
}

private actor ControlledModelAdapter: LocalModelLoading {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var loading = false
    private(set) var loads = 0
    private(set) var unloads = 0
    func load(folder: URL) async throws {
        loads += 1; loading = true
        // Ein nativer CoreML-Aufruf kann Cancellation ignorieren. Der Test gibt
        // ihn ausdrücklich frei, damit ein verspäteter Erfolg reproduzierbar bleibt.
        await withCheckedContinuation { continuation = $0 }
        loading = false
    }
    func finishLoading() { continuation?.resume(); continuation = nil }
    func unload() async { unloads += 1 }
}

private struct SessionModelDownloader: LocalModelDownloading {
    let data: Data
    func download(_ file: LocalModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try data.write(to: destination); progress(Int64(data.count))
    }
}
