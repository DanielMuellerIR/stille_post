import Foundation

public extension Config {
    struct ProfileSelection: Equatable, Sendable {
        public enum Reason: Equatable, Sendable { case manual, application, standard, global }
        public let profileID: UUID?
        public let reason: Reason
        public let appBundleID: String?
        public let missingAppProfile: Bool

        public var label: String {
            if missingAppProfile { return L10n.text("profiles.reason.missing") }
            switch reason {
            case .manual: return L10n.text("profiles.reason.manual")
            case .application: return L10n.format("profiles.reason.app", appBundleID ?? "")
            case .standard: return L10n.text("profiles.reason.default")
            case .global: return L10n.text("profiles.reason.global")
            }
        }
    }

    func profileSelection(appBundleID: String? = nil) -> ProfileSelection {
        func exists(_ id: UUID?) -> Bool { id.map { id in profiles.contains { $0.id == id } } ?? false }
        if exists(selectedProfileID) { return ProfileSelection(profileID: selectedProfileID, reason: .manual, appBundleID: nil, missingAppProfile: false) }
        let rule = appBundleID.flatMap { appProfiles[$0] }
        if exists(rule) { return ProfileSelection(profileID: rule, reason: .application, appBundleID: appBundleID, missingAppProfile: false) }
        let hasDefault = exists(defaultProfileID)
        return ProfileSelection(profileID: hasDefault ? defaultProfileID : nil, reason: hasDefault ? .standard : .global,
                                appBundleID: appBundleID, missingAppProfile: rule != nil)
    }

    static func validAppBundleID(_ value: String) -> Bool {
        (3...255).contains(value.count) && value.contains(".") && value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
}

struct AppProfileRules: Decodable {
    var values: [String: UUID] = [:]
    init() {}
    init(from decoder: Decoder) throws {
        let rules = try decoder.singleValueContainer().decode([String: Target].self)
        for (app, target) in rules where Config.validAppBundleID(app) {
            if let id = target.id { values[app] = id }
        }
    }
    private struct Target: Decodable {
        let id: UUID?
        init(from decoder: Decoder) throws { id = try? decoder.singleValueContainer().decode(UUID.self) }
    }
}
