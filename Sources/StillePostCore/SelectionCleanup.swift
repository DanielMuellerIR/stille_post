import Foundation

public enum SelectionCleanupFailure: Error, LocalizedError {
    case empty, tooLarge, noAccess, permission, changed, unsupported, busy, emptyOutput, noTarget, secure, unconfirmed, configuration
    public var errorDescription: String? { L10n.text("selection.error.\(self)") }
}

/// Vergleicht genau die ursprünglich ausgewählte Stelle, ohne den restlichen
/// Dokumentinhalt zu benötigen. Die App liefert opake Prozess-/Elementidentitäten.
public struct TextSelectionSnapshot: Equatable, Sendable {
    public static let maximumUTF8Bytes = 8192
    public let applicationIdentity: String
    public let elementIdentity: UUID
    public let range: NSRange
    public let text: String
    public let supportsReplacement: Bool

    public init(applicationIdentity: String, elementIdentity: UUID, range: NSRange,
                text: String, supportsReplacement: Bool) throws {
        try Self.validate(text)
        guard range.location >= 0, range.location != NSNotFound, range.length == text.utf16.count,
              range.length > 0, range.location <= Int.max - range.length else { throw SelectionCleanupFailure.changed }
        self.applicationIdentity = applicationIdentity; self.elementIdentity = elementIdentity
        self.range = range; self.text = text; self.supportsReplacement = supportsReplacement
    }

    public static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumUTF8Bytes else { throw SelectionCleanupFailure.tooLarge }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SelectionCleanupFailure.empty }
    }

    public func permitsReplacement(with current: Self, foreignApplicationActivated: Bool) -> Bool {
        !foreignApplicationActivated && supportsReplacement && current.supportsReplacement
            && applicationIdentity == current.applicationIdentity && elementIdentity == current.elementIdentity
            && range == current.range && text.utf8.elementsEqual(current.text.utf8)
    }
}

/// Ein ausdrücklich angeforderter Textauftrag ohne Aufnahme, Verlauf oder
/// letzten Diktattext. Schließen entwertet auch eine verspätete Modellantwort.
@MainActor public final class SelectionCleanupSession {
    public enum State: Equatable { case idle, processing, preview, cancelled, failed(String) }
    public typealias Cleaner = (Config.Cleanup, String) async -> CleanupService.Result
    public var onChange: (() -> Void)?
    public private(set) var state = State.idle
    public private(set) var input: String?
    public private(set) var configuration: Config?
    public private(set) var result: CleanupService.Result?
    public var hasRequest: Bool { input != nil }
    public var isActive: Bool { state == .processing }
    private var generation = 0
    private var task: Task<Void, Never>?

    public init() {}
    deinit { task?.cancel() }

    public func start(text: String, configuration: Config, appBundleID: String?, requiresLocalOnly: Bool = false,
                      cleaner: Cleaner? = nil) throws {
        guard !hasRequest else { throw SelectionCleanupFailure.busy }
        try TextSelectionSnapshot.validate(text)
        var frozen = configuration.resolvedForRequest(appBundleID: appBundleID)
        if requiresLocalOnly { frozen.cleanup.localOnly = true }
        self.input = text; self.configuration = frozen; result = nil
        generation += 1; let token = generation
        state = .processing
        let perform = cleaner ?? { cleanup, input in await CleanupService(config: cleanup).clean(input) }
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let completed = await perform(frozen.cleanup, text)
            guard let self, !Task.isCancelled, self.generation == token, self.state == .processing else { return }
            self.task = nil
            if completed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.state = .failed(SelectionCleanupFailure.emptyOutput.localizedDescription)
            } else { self.result = completed; self.state = .preview }
            self.onChange?()
        }
        onChange?()
    }

    public func close() {
        generation += 1; task?.cancel(); task = nil
        input = nil; configuration = nil; result = nil; state = .cancelled
        onChange?()
    }
}
