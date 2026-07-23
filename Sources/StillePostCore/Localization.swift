import Foundation

/// Gemeinsame Lokalisierung für App, Core-Fehler und CLI.
///
/// Die Texte liegen absichtlich im Core-Target: GUI und Kommandozeile zeigen dadurch
/// dieselben Meldungen in derselben Sprache. Normalerweise wählt macOS die Sprache.
/// `STILLEPOST_LANGUAGE=de|en` ist nur ein reproduzierbarer Testweg für headless
/// GUI-Prüfungen und Screenshots.
public enum L10n {
    private static let supportedLanguages = ["de", "en"]

    /// Ressourcen-Bundle von StillePostCore — robust in JEDER Verpackung.
    ///
    /// SwiftPMs generiertes `Bundle.module` sucht das Bundle nur im Wurzel-
    /// verzeichnis der laufenden `.app` UND unter dem fest einkompilierten
    /// Build-Pfad der Build-Maschine. In der ausgelieferten App liegt es aber
    /// unter `Contents/Resources` (siehe scripts/build-app.sh) bzw. — für die
    /// eingebettete CLI — neben dem Executable. Ohne diese eigene Auflösung
    /// stürzt die App deshalb auf JEDEM Rechner außer der Build-Maschine sofort
    /// beim Start mit einem `Bundle.module`-fatalError ab (Vorfall M5, 0.8.13).
    /// Kandidaten in dieser Reihenfolge, erster Treffer gewinnt; ganz zuletzt
    /// SwiftPMs `Bundle.module` (greift nur noch in Tests / auf der Build-Maschine).
    private static let resourceBundle: Bundle = {
        let bundleName = "StillePost_StillePostCore.bundle"
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))     // App: Contents/Resources
        }
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDir.appendingPathComponent(bundleName))   // CLI: neben dem Executable
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName)) // SwiftPM-Erwartung: .app-Wurzel
        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }()

    private static var selectedLanguage: String? {
        guard let requested = ProcessInfo.processInfo.environment["STILLEPOST_LANGUAGE"],
              supportedLanguages.contains(requested) else {
            return nil
        }
        return requested
    }

    private static var selectedBundle: Bundle {
        selectedLanguage.flatMap(bundle(for:)) ?? resourceBundle
    }

    /// Aktive Sprache, z. B. für sprachgerechte Zahlenformatierung.
    public static var languageCode: String {
        selectedLanguage
            ?? selectedBundle.preferredLocalizations.first
            ?? resourceBundle.developmentLocalization
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
        (bundle(for: language) ?? resourceBundle)
            .localizedString(forKey: key, value: key, table: nil)
    }

    /// Test-Helfer: alle Schlüssel einer Sprachdatei. So fällt schon im Unit-Test
    /// auf, wenn Deutsch und Englisch auseinanderlaufen.
    static func keys(language: String) -> Set<String> {
        guard let url = resourceBundle.url(
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
              let path = resourceBundle.path(forResource: language, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
