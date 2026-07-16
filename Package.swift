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
    targets: [
        .target(
            name: "StillePostCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "StillePost",
            dependencies: ["StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
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
