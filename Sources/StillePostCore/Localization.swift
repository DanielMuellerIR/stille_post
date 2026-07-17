import Foundation

/// Gemeinsame Lokalisierung für App, Core-Fehler und CLI.
///
/// Die Texte liegen absichtlich im Core-Target: GUI und Kommandozeile zeigen dadurch
/// dieselben Meldungen in derselben Sprache. Normalerweise wählt macOS die Sprache.
/// `STILLEPOST_LANGUAGE=de|en` ist nur ein reproduzierbarer Testweg für headless
/// GUI-Prüfungen und Screenshots.
public enum L10n {
    private static let supportedLanguages = ["de", "en"]

    private static var selectedLanguage: String? {
        guard let requested = ProcessInfo.processInfo.environment["STILLEPOST_LANGUAGE"],
              supportedLanguages.contains(requested) else {
            return nil
        }
        return requested
    }

    private static var selectedBundle: Bundle {
        selectedLanguage.flatMap(bundle(for:)) ?? Bundle.module
    }

    /// Aktive Sprache, z. B. für sprachgerechte Zahlenformatierung.
    public static var languageCode: String {
        selectedLanguage
            ?? selectedBundle.preferredLocalizations.first
            ?? Bundle.module.developmentLocalization
            ?? "de"
    }

    /// Liefert einen lokalisierten Text ohne Platzhalter.
    public static func text(_ key: String) -> String {
        selectedBundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Liefert einen lokalisierten Text mit printf-Platzhaltern.
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: languageCode), arguments: arguments)
    }

    /// Explizite Sprachwahl für Tests, ohne die Prozesssprache umzuschalten.
    public static func text(_ key: String, language: String) -> String {
        (bundle(for: language) ?? Bundle.module)
            .localizedString(forKey: key, value: key, table: nil)
    }

    /// Test-Helfer: alle Schlüssel einer Sprachdatei. So fällt schon im Unit-Test
    /// auf, wenn Deutsch und Englisch auseinanderlaufen.
    static func keys(language: String) -> Set<String> {
        guard let url = Bundle.module.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: language
        ),
        let dictionary = NSDictionary(contentsOf: url) as? [String: String] else {
            return []
        }
        return Set(dictionary.keys)
    }

    private static func bundle(for language: String) -> Bundle? {
        guard supportedLanguages.contains(language),
              let path = Bundle.module.path(forResource: language, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
