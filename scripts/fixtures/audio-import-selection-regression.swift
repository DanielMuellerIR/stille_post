import AppKit
import UniformTypeIdentifiers
import StillePostCore

// Prüft echte verzögerte NSItemProvider-Antworten ohne Fenster oder Netz;
// die gemeinsame Zwischenablage wird nur über ihren Änderungszähler beobachtet.
@main struct AudioImportSelectionRegression {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.wav"), latest = root.appendingPathComponent("latest.m4a")
        for url in [first, latest] { try Data(repeating: 0, count: 64).write(to: url) }
        let plain = root.appendingPathComponent("plain.txt"); try Data("synthetic".utf8).write(to: plain)
        let clipboard = NSPasteboard.general.changeCount
        let config = Config()
        let model = AudioImportViewModel(engine: { nil }, configuration: { config },
            nextConfiguration: { config }, canStart: { true }, onBegin: { fatalError("Kein Auftrag erwartet") },
            onClosingError: { _ in fatalError("Kein laufender Auftrag") })
        model.open()
        let slow = DeferredFileURL(first)
        guard model.acceptDrop([slow.provider]), model.isSelecting else { throw Failure.state }
        try await wait { slow.entered }
        let selected = model.beginSelection(); model.completeSelection(selected, url: latest)
        slow.finish(); try await Task.sleep(nanoseconds: 100_000_000)
        guard model.selectedURL == latest, !model.isSelecting, model.selectionError == nil else { throw Failure.stale }

        let closed = DeferredFileURL(first)
        guard model.acceptDrop([closed.provider]) else { throw Failure.state }
        try await wait { closed.entered }; model.close(); closed.finish()
        try await Task.sleep(nanoseconds: 100_000_000)
        guard model.selectedURL == nil, !model.isSelecting else { throw Failure.closed }

        model.open()
        let cancelled = model.beginSelection(); model.cancelSelection(cancelled)
        model.completeSelection(cancelled, url: first)
        guard model.selectedURL == nil else { throw Failure.stale }
        let provider = NSItemProvider(contentsOf: first)!
        guard !model.acceptDrop([provider, provider]), model.selectionError != nil, model.selectedURL == nil else { throw Failure.multiple }
        let invalid = model.beginSelection(); model.completeSelection(invalid, url: plain)
        guard model.selectionError != nil, model.selectedURL == nil else { throw Failure.invalid }
        let authority = model.beginSelection(); model.completeSelection(authority, url: URL(string: "file://remote.invalid/audio.wav"))
        guard model.selectionError != nil, model.selectedURL == nil else { throw Failure.invalid }
        let remote = model.beginSelection(); model.completeSelection(remote, url: URL(string: "https://example.invalid/audio.wav"))
        guard model.selectionError != nil, model.selectedURL == nil else { throw Failure.invalid }
        let directory = model.beginSelection(); model.completeSelection(directory, url: root)
        guard model.selectionError != nil else { throw Failure.invalid }
        let good = DeferredFileURL(first)
        guard model.acceptDrop([good.provider]) else { throw Failure.state }
        try await wait { good.entered }; good.finish()
        try await wait { model.selectedURL == first }
        guard !model.isSelecting, model.state == .ready, model.selectionError == nil,
              NSPasteboard.general.changeCount == clipboard else { throw Failure.state }
        model.close()
        print("PASS Audioauswahl: verspäteter Drop, neuere Auswahl, Schließen, Abbrechen, Mehrfach-/Nichtaudio-/Netz-/Ordnereingabe, kein automatischer Start oder Clipboard-Zugriff")
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure.timeout
    }
    enum Failure: Error { case state, stale, closed, multiple, invalid, timeout }
}

private final class DeferredFileURL: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private let url: URL
    private var completion: ((Data?, Error?) -> Void)?
    var entered: Bool { lock.withLock { completion != nil } }
    init(_ url: URL) {
        self.url = url
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { [weak self] completion in
            self?.lock.withLock { self?.completion = completion }
            return nil
        }
    }
    func finish() {
        let callback = lock.withLock { let value = completion; completion = nil; return value }
        callback?(url.dataRepresentation, nil)
    }
}
