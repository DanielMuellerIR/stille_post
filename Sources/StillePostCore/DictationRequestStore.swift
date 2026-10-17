import Foundation

/// Ein Lock veröffentlicht Sprache, Bereinigung und Datenschutz gemeinsam.
/// Dienste im Snapshot bleiben unveränderlich, auch wenn der nächste Auftrag
/// inzwischen ein anderes Profil verwendet. Der Server gehört zum App-Lifecycle.
final class DictationRequestStore: @unchecked Sendable {
    struct Snapshot {
        let config: Config
        let transcriber: any DictationTranscriber
        let cleanup: any DictationCleanup
    }

    private let lock = NSLock()
    private var value: Snapshot
    private let makeTranscriber: ((Config.Whisper) -> any DictationTranscriber)?

    init(config: Config, transcriber: any DictationTranscriber, cleanup: any DictationCleanup,
         makeTranscriber: ((Config.Whisper) -> any DictationTranscriber)? = nil) {
        value = Snapshot(config: config.resolvedForRequest(), transcriber: transcriber, cleanup: cleanup)
        self.makeTranscriber = makeTranscriber
    }

    func snapshot() -> Snapshot { lock.withLock { value } }

    func configure(_ config: Config) {
        lock.withLock { replace(config.resolvedForRequest()) }
    }

    func configureHistory(_ history: Config.History) {
        lock.withLock {
            var config = value.config
            config.history = history
            replace(config)
        }
    }

    func configureVocabulary(_ vocabulary: Config.Cleanup) {
        lock.withLock {
            var config = value.config
            config.cleanup.dictionary = vocabulary.dictionary
            config.cleanup.dictionaryVariants = vocabulary.dictionaryVariants
            replace(config)
        }
    }

    private func replace(_ config: Config) {
        var transcriber = value.transcriber
        if config.whisper != value.config.whisper {
            if let makeTranscriber { transcriber = makeTranscriber(config.whisper) }
            else if transcriber is WhisperClient { transcriber = WhisperClient(config: config.whisper) }
        }
        let cleanup = (value.cleanup as? CleanupService)?.replacingConfiguration(with: config.cleanup) ?? value.cleanup
        value = Snapshot(config: config, transcriber: transcriber, cleanup: cleanup)
    }
}
