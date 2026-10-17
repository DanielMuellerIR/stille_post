import Foundation

public extension Config {
    struct Profile: Codable, Equatable, Identifiable {
        public let id: UUID
        public var name: String
        public var language: String?
        public var vocabulary: Vocabulary?
        public var cleanup: CleanupOptions?
        public var history: History?

        public init(id: UUID = UUID(), name: String) {
            self.id = id
            self.name = name
        }
    }

    struct Vocabulary: Codable, Equatable {
        public var dictionary: [String]
        public var dictionaryVariants: [DictionaryVariant]

        public init(_ cleanup: Cleanup) {
            dictionary = cleanup.dictionary
            dictionaryVariants = cleanup.dictionaryVariants
        }

        private enum CodingKeys: String, CodingKey { case dictionary, dictionaryVariants }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            dictionary = try values.decodeIfPresent([String].self, forKey: .dictionary) ?? []
            dictionaryVariants = try values.decodeIfPresent([DictionaryVariant].self, forKey: .dictionaryVariants) ?? []
        }

        public func applying(to cleanup: Cleanup) -> Cleanup {
            var result = cleanup
            result.dictionary = dictionary
            result.dictionaryVariants = dictionaryVariants
            return result
        }
    }

    /// Wörterbuch und Dienstwahl vererben unabhängig voneinander.
    struct CleanupOptions: Codable, Equatable {
        public var enabled: Bool
        public var localOnly: Bool?
        public var primary: Cleanup.Endpoint
        public var fallbacks: [Cleanup.Endpoint]

        public init(_ cleanup: Cleanup) {
            enabled = cleanup.enabled
            localOnly = cleanup.localOnly
            primary = cleanup.chain[0]
            fallbacks = cleanup.fallbacks
        }

        private enum CodingKeys: String, CodingKey { case enabled, localOnly, primary, fallbacks }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            primary = try c.decode(Cleanup.Endpoint.self, forKey: .primary)
            fallbacks = try c.decode([Cleanup.Endpoint].self, forKey: .fallbacks)
            localOnly = c.contains(.localOnly) ? ((try? c.decode(Bool.self, forKey: .localOnly)) ?? true) : nil
        }

        public func applying(to cleanup: Cleanup) -> Cleanup {
            var result = cleanup
            result.enabled = enabled
            result.localOnly = localOnly ?? cleanup.localOnly
            result.provider = primary.provider
            result.ollamaURL = primary.ollamaURL
            result.model = primary.model
            result.numCtx = primary.numCtx
            result.keepAlive = primary.keepAlive
            result.remote = primary.remote
            result.fallbacks = fallbacks
            return result
        }
    }

    var activeProfile: Profile? {
        let id = requestProfileSelection?.profileID ?? (requestProfileSelection == nil ? profileSelection().profileID : nil)
        return profiles.first { $0.id == id }
    }

    var profileLabel: String {
        activeProfile?.name ?? L10n.text("profiles.global")
    }

    /// Wertkopie am Auftragsstart; nachfolgende Auswahländerungen erreichen sie nicht.
    func resolvedForRequest(appBundleID: String? = nil) -> Config {
        if requestProfileSelection != nil { return self }
        var result = self
        result.requestProfileSelection = profileSelection(appBundleID: appBundleID)
        if let profile = result.activeProfile {
            result.whisper.language = profile.language ?? whisper.language
            result.cleanup = profile.cleanup?.applying(to: cleanup) ?? cleanup
            result.cleanup = profile.vocabulary?.applying(to: result.cleanup) ?? result.cleanup
            result.history = profile.history ?? history
        }
        return result
    }

    mutating func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        appProfiles = appProfiles.filter { $0.value != id }
        if selectedProfileID == id { selectedProfileID = nil }
        if defaultProfileID == id { defaultProfileID = nil }
    }

    /// Der Wörterbuch-Scope wird für einen geöffneten Editor festgehalten.
    var vocabularyProfileID: UUID? {
        activeProfile.flatMap { $0.vocabulary == nil ? nil : $0.id }
    }

    func validateProfiles() throws {
        guard appProfiles.count <= 200, appProfiles.keys.allSatisfy(Self.validAppBundleID),
              profiles.count <= 50, Set(profiles.map(\.id)).count == profiles.count else {
            throw ProfileFailure.invalid
        }
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.count <= 40,
                  !profile.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  profile.language.map({ Self.validProfileLanguage($0) }) ?? true,
                  profile.history?.isValid ?? true else { throw ProfileFailure.invalid }
            try VocabularyRules.validate(profile.vocabulary?.applying(to: cleanup) ?? cleanup)
        }
    }

    static func validProfileLanguage(_ language: String) -> Bool {
        language == "auto" || ((2...3).contains(language.count) && language.utf8.allSatisfy { (97...122).contains($0) })
    }

    enum ProfileFailure: Error, LocalizedError {
        case invalid, missing
        public var errorDescription: String? {
            L10n.text(self == .invalid ? "profiles.invalid" : "profiles.missing")
        }
    }
}

/// Ungültige IDs werden nie beim Laden neu vergeben. Defekte Einzelprofile
/// dürfen außerdem nicht gültige globale Einstellungen oder Nachbarn verwerfen.
struct ProfileCollection: Decodable {
    var profiles: [Config.Profile] = []
    init() {}
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        while !values.isAtEnd {
            let value = try values.decode(Record.self)
            if let profile = value.profile { profiles.append(profile) }
        }
        let counts = Dictionary(grouping: profiles, by: \.id)
        profiles.removeAll { counts[$0.id]!.count > 1 }
    }
    private struct Record: Decodable {
        let profile: Config.Profile?
        init(from decoder: Decoder) throws { profile = try? Config.Profile(from: decoder) }
    }
}
