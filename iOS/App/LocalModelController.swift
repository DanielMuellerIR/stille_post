import Combine
import Foundation
import StillePostClientCore
import UIKit

@MainActor final class LocalModelController: ObservableObject, OfflineDictating {
    @Published private(set) var state: LocalModelState
    private let session: LocalModelSession?
    private var previousIdleTimer: Bool?
    private var awakeTask: Task<Void, Never>?
    private var awakeDeadline: ContinuousClock.Instant?
    private let decoder = LocalPCMDecoder()

    init() {
        do {
            let catalog = try LocalModelCatalog.bundled()
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OfflineModel", isDirectory: true)
            let store: LocalModelStore
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["STILLEPOST_MOBILE_MODEL_EMPTY_CAPACITY"] == "1" {
                store = try LocalModelStore(directory: directory, catalog: catalog, capacity: { _ in 0 })
            } else { store = try LocalModelStore(directory: directory, catalog: catalog) }
            #else
            store = try LocalModelStore(directory: directory, catalog: catalog)
            #endif
            let session = LocalModelSession(store: store, totalBytes: catalog.totalBytes, adapter: LocalWhisperAdapter())
            self.session = session; state = session.state
            session.onChange = { [weak self] in self?.receive($0) }
        } catch {
            session = nil
            state = LocalModelState(failure: .invalidCatalog)
        }
    }

    func refresh() { session?.refresh() }
    func download() { session?.download() }
    func load() { session?.load() }
    func release() { session?.release() }
    func remove() { session?.remove() }
    func interrupt(_ reason: LocalModelInterruption) { session?.interrupt(reason) }

    func transcribe(_ recording: Recording, language: DictationLanguage,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let session else { throw LocalModelFailure.invalidCatalog }
        guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { throw ClientFailure.tooHot }
        let samples = try await decoder.decode(recording)
        try Task.checkCancellation()
        return try await session.transcribe(samples: samples, language: language, progress: progress)
    }

    private func receive(_ state: LocalModelState) {
        self.state = state
        guard [.downloading, .validating, .loading, .recognizing].contains(state.phase) else {
            restoreIdleTimer(); awakeDeadline = nil; return
        }
        guard UIApplication.shared.applicationState == .active else { restoreIdleTimer(); return }
        let deadline = awakeDeadline ?? ContinuousClock.now.advanced(by: .seconds(600))
        awakeDeadline = deadline
        guard previousIdleTimer == nil, ContinuousClock.now < deadline else { return }
        // Eine mehrminütige erste Aufbereitung soll nicht an der normalen
        // Displayfrist scheitern. Manuelle Sperre/Hintergrund bleiben wirksam.
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        awakeTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            self?.restoreIdleTimer()
        }
    }

    private func restoreIdleTimer() {
        awakeTask?.cancel(); awakeTask = nil
        if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        previousIdleTimer = nil
    }
}
