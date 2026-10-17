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
    private var configuration: Config
    private var lastAppBundleID: String?
    private let makeTranscriber: ((Config.Whisper) -> any DictationTranscriber)?

    init(config: Config, transcriber: any DictationTranscriber, cleanup: any DictationCleanup,
         makeTranscriber: ((Config.Whisper) -> any DictationTranscriber)? = nil) {
        configuration = config
        value = Snapshot(config: config.resolvedForRequest(), transcriber: transcriber, cleanup: cleanup)
        self.makeTranscriber = makeTranscriber
    }

    func snapshot(appBundleID: String? = nil) -> Snapshot {
        lock.withLock {
            lastAppBundleID = appBundleID
            replace(configuration.resolvedForRequest(appBundleID: appBundleID))
            return value
        }
    }

    func configure(_ config: Config) {
        lock.withLock {
            configuration = config
            replace(config.resolvedForRequest(appBundleID: lastAppBundleID))
        }
    }

    func configureHistory(_ history: Config.History) {
        lock.withLock {
            var config = configuration
            config.history = history
            configuration = config
            replace(config.resolvedForRequest(appBundleID: lastAppBundleID))
        }
    }

    func configureVocabulary(_ vocabulary: Config.Cleanup) {
        lock.withLock {
            var config = configuration
            config.cleanup.dictionary = vocabulary.dictionary
            config.cleanup.dictionaryVariants = vocabulary.dictionaryVariants
            configuration = config
            replace(config.resolvedForRequest(appBundleID: lastAppBundleID))
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
