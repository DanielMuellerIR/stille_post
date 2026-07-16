// swift-tools-version:6.0
// Stille Post — lokale Diktier-App (Whisper-STT + LLM-Textbereinigung), Ersatz für OpenWhispr.
// Aufbau:
//   StillePostCore  — die gesamte Logik ohne GUI (Aufnahme, VAD, Whisper, Ollama, Verlauf).
//                     Bewusst getrennt, damit CLI und Tests dieselbe Logik nutzen wie die App.
//   StillePost      — die Menüleisten-App (Hotkey, Overlay, Verlaufsfenster).
//   stillepost-cli  — Headless-Zugang für Tests und AI-Agenten (transcribe/cleanup/doctor/history).
import PackageDescription

let package = Package(
    name: "StillePost",
    platforms: [
        // Untergrenze macOS 13: SMAppService (Login-Item) und die
        // Settings-Form-APIs (.formStyle/LabeledContent) brauchen Ventura.
        .macOS(.v13)
    ],
    dependencies: [
        // Exakt pinnen: Ein Updater läuft mit hohen Rechten im Installationspfad.
        // Versionssprünge werden deshalb bewusst geprüft statt still übernommen.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .target(
            name: "StillePostCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "StillePost",
            dependencies: [
                "StillePostCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Das Release-Skript legt Sparkle im üblichen App-Bundle-Ordner ab.
                // SwiftPM ergänzt für Binär-Targets nur @loader_path (neben dem
                // Executable); diesen Bundle-rpath müssen wir daher selbst setzen.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "stillepost-cli",
            dependencies: ["StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StillePostCoreTests",
            dependencies: ["StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
