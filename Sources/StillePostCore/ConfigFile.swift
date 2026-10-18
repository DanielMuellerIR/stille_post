import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Laden für Änderungen, Prüfen und atomarer Schreibabschluss teilen denselben Dateilock.
/// Wörterbuchaktionen ändern nur ihre Felder im frischen Konfigurationsstand.
public final class ConfigFile: @unchecked Sendable {
    public let url: URL

    public init(url: URL = Config.configFile) { self.url = url }

    public enum Failure: Error, LocalizedError {
        case conflict
        public var errorDescription: String? { L10n.text("core.config.save_conflict") }
    }

    public func load() throws -> Config {
        try locked { try read() }
    }

    /// Reine Aufträge lesen die atomar ausgetauschte Datei ohne Schreiblock.
    /// Defekte Daten dürfen dabei keine gespeicherte Datenschutzregel durch
    /// Standardwerte ersetzen und deshalb nicht still abgefangen werden.
    public func loadSnapshot() throws -> Config { try read() }

    public func save(_ config: Config, expected: Config? = nil) throws {
        try locked {
            if let expected, try read() != expected { throw Failure.conflict }
            try write(config)
        }
    }

    public func addVocabulary(term: String, variant: String?, profileID: UUID? = nil) throws -> Config {
        try locked {
            var config = try read()
            if let profileID {
                guard let index = config.profiles.firstIndex(where: { $0.id == profileID }),
                      let vocabulary = config.profiles[index].vocabulary else { throw Config.ProfileFailure.missing }
                let updated = try VocabularyRules.adding(term: term, variant: variant, to: vocabulary.applying(to: config.cleanup))
                config.profiles[index].vocabulary = Config.Vocabulary(updated)
            } else {
                config.cleanup = try VocabularyRules.adding(term: term, variant: variant, to: config.cleanup)
            }
            try write(config)
            return config
        }
    }

    public func selectProfile(_ id: UUID?) throws -> Config {
        try locked {
            var config = try read()
            if let id, !config.profiles.contains(where: { $0.id == id }) { throw Config.ProfileFailure.missing }
            config.selectedProfileID = id
            try write(config)
            return config
        }
    }

    private func read() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    private func write(_ config: Config) throws {
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = url.appendingPathExtension("lock").path.withCString {
            open($0, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }
}
