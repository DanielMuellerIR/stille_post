import Foundation

public enum AppVersion {
    public static var current: String {
#if os(Linux)
        LinuxInstallation.version
#else
        // Außerhalb des App-Bundles, etwa bei einem SwiftPM-CLI-Lauf, fehlt der Eintrag.
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
#endif
    }
}
