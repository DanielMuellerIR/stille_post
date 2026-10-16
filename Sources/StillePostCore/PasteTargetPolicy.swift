import Foundation

/// Entscheidet ohne AppKit-Zugriff, ob das ursprüngliche Diktierziel noch passt.
/// Fehlende Zielinformationen erlauben kein automatisches Einfügen.
public enum PasteTargetPolicy {
    public struct ApplicationIdentity: Equatable, Sendable {
        public let processIdentifier: Int32
        public let bundleIdentifier: String

        public init(processIdentifier: Int32, bundleIdentifier: String) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public enum ElementMatch: Sendable {
        case same, different, unavailable
    }

    public enum Decision: Equatable, Sendable {
        case paste
        case clipboardOnlyTargetChanged
        case clipboardOnlyTargetUnavailable
        case clipboardOnlyScreenSharing
        case noPermission
    }

    public static func decide(
        originalApplication: ApplicationIdentity?,
        currentApplication: ApplicationIdentity?,
        window: ElementMatch,
        field: ElementMatch,
        accessibilityGranted: Bool,
        screenSharingActive: Bool
    ) -> Decision {
        guard accessibilityGranted else { return .noPermission }
        if screenSharingActive { return .clipboardOnlyScreenSharing }
        guard let originalApplication, let currentApplication else {
            return .clipboardOnlyTargetUnavailable
        }
        guard originalApplication == currentApplication else {
            return .clipboardOnlyTargetChanged
        }
        if window == .different || field == .different { return .clipboardOnlyTargetChanged }
        guard window == .same, field == .same else { return .clipboardOnlyTargetUnavailable }
        return .paste
    }
}
