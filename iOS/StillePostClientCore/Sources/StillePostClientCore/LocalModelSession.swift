import Foundation

public protocol LocalModelLoading: Sendable {
    func load(folder: URL) async throws
    func unload() async
}

public enum LocalModelPhase: String, Sendable {
    case checking, missing, partial, downloading, validating, available, loading, loaded, stopping, failed
}

public enum LocalModelInterruption: String, Sendable { case paused, background, memory, closed }

public struct LocalModelState: Equatable, Sendable {
    public internal(set) var phase: LocalModelPhase = .checking
    public internal(set) var downloadedBytes: Int64 = 0
    public let totalBytes: Int64
    public internal(set) var installed = false
    public internal(set) var failure: LocalModelFailure?
    public internal(set) var notice: LocalModelInterruption?
    public var busy: Bool { [.checking, .downloading, .validating, .loading, .stopping].contains(phase) }
    public init(totalBytes: Int64) { self.totalBytes = totalBytes }
    public init(failure: LocalModelFailure) { totalBytes = 0; phase = .failed; self.failure = failure }
}

@MainActor public final class LocalModelSession {
    public private(set) var state: LocalModelState { didSet { onChange?(state) } }
    public var onChange: ((LocalModelState) -> Void)?
    private let store: LocalModelStore
    private let adapter: any LocalModelLoading
    private let downloader: any LocalModelDownloading
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private enum Action { case inspect, download, load, release, remove }

    public init(store: LocalModelStore, totalBytes: Int64, adapter: any LocalModelLoading,
                downloader: any LocalModelDownloading = HTTPSModelDownloader()) {
        self.store = store; self.adapter = adapter; self.downloader = downloader
        state = LocalModelState(totalBytes: totalBytes)
    }

    public func refresh() { if state.phase != .loaded { begin(.inspect) } }
    public func download() { if !state.installed { begin(.download) } }
    public func load() { if state.installed, state.phase != .loaded { begin(.load) } }
    public func release() { if state.phase == .loaded { begin(.release) } }
    public func remove() { begin(.remove) }

    public func interrupt(_ reason: LocalModelInterruption) {
        guard task != nil || state.phase == .loaded else { return }
        state.notice = reason
        if let task {
            task.cancel(); state.phase = .stopping
        } else { begin(.release, preservingNotice: true) }
    }

    private func begin(_ action: Action, preservingNotice: Bool = false) {
        guard task == nil else { return }
        generation = UUID(); let current = generation
        var next = state
        next.failure = nil
        if !preservingNotice { next.notice = nil }
        switch action {
        case .inspect: next.phase = .checking
        case .download: next.phase = .downloading
        case .load: next.phase = .validating
        case .release, .remove: next.phase = .stopping
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                switch action {
                case .inspect: break
                case .download:
                    try await store.install(using: downloader) { [weak self] count in
                        Task { @MainActor in
                            guard let self, self.generation == current, self.state.phase == .downloading else { return }
                            self.state.downloadedBytes = min(max(0, count), self.state.totalBytes)
                        }
                    }
                case .load:
                    let folder = try await store.validateInstalled()
                    try Task.checkCancellation()
                    state.phase = .loading
                    try Task.checkCancellation()
                    try await adapter.load(folder: folder)
                    try Task.checkCancellation()
                    state.phase = .loaded
                    return
                case .release: await adapter.unload()
                case .remove:
                    await adapter.unload()
                    try await store.remove()
                }
                try Task.checkCancellation()
                await updateInventory()
            } catch is CancellationError {
                // CoreML-Laden kann trotz Cancellation weiterlaufen. Erst nach seiner
                // Rückkehr freigeben und neue Aktionen wieder zulassen.
                await adapter.unload()
                await updateInventory()
            } catch {
                await adapter.unload()
                await updateInventory()
                state.failure = error as? LocalModelFailure ?? .storage
                state.phase = .failed
            }
        }
        state = next
    }

    private func updateInventory() async {
        do {
            let inventory = try await store.inventory()
            state.installed = inventory.installed
            state.downloadedBytes = inventory.downloadedBytes
            state.phase = inventory.installed ? .available : inventory.downloadedBytes > 0 ? .partial : .missing
        } catch {
            state.failure = error as? LocalModelFailure ?? .storage; state.phase = .failed
        }
    }
}
