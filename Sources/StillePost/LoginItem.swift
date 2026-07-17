import Foundation
import ServiceManagement
import StillePostCore

/// „Beim Anmelden starten" — meldet die App als Login-Item an oder ab.
///
/// Bewusst NICHT in `config.json`: Das ist Zustand des Systems, nicht der App. Läge
/// er in unserer Konfiguration, könnten beide auseinanderlaufen (Nutzer schaltet es
/// in den Systemeinstellungen unter „Anmeldeobjekte" aus, unsere Datei behauptet
/// weiter „an"). Deshalb ist `SMAppService` hier die einzige Wahrheit.
enum LoginItem {

    /// Läuft die App überhaupt so, dass ein Login-Item möglich ist?
    ///
    /// `SMAppService.mainApp` braucht ein echtes App-Bundle mit Bundle-Identifier.
    /// Beim Entwickeln über `swift run` gibt es keins — dann wäre der Schalter eine
    /// Attrappe, und wir zeigen ihn lieber abgeschaltet mit Begründung.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Ist die App aktuell als Login-Item registriert?
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Meldet die App an oder ab. Wirft mit einer Meldung, die man dem Nutzer zeigen kann.
    static func setEnabled(_ enabled: Bool) throws {
        guard isAvailable else { throw LoginItemError.noBundle }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Erklärt den aktuellen Zustand in einem Satz — auch die Fälle, die man sonst
    /// nur als kryptischen Fehler sieht.
    static var explanation: String? {
        // Screenshot-Test aus einem nicht installierten Build: Den künstlichen
        // `.notFound`-Hinweis ausblenden, ohne den echten Systemzustand zu ändern.
        if ProcessInfo.processInfo.environment["STILLEPOST_LOGIN_ITEM_PREVIEW"] != nil {
            return nil
        }
        guard isAvailable else {
            return L10n.text("settings.login_item.unavailable")
        }
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            return L10n.text("settings.login_item.approval")
        case .notFound:
            return L10n.text("settings.login_item.not_found")
        default:
            return nil
        }
    }

    enum LoginItemError: LocalizedError {
        case noBundle
        var errorDescription: String? {
            L10n.text("settings.login_item.error_no_bundle")
        }
    }
}
