// swift-tools-version:6.0
// Stille Post — lokale Diktier-App (Whisper-STT + LLM-Textbereinigung), Ersatz für OpenWhispr.
// Aufbau:
//   StillePostCore  — die gesamte Logik ohne GUI (Aufnahme, VAD, Whisper, Ollama, Verlauf).
//                     Bewusst getrennt, damit CLI und Tests dieselbe Logik nutzen wie die App.
//   StillePost      — die Menüleisten-App (Hotkey, Overlay, Verlaufsfenster).
//   stillepost-cli  — Headless-Zugang für Tests und AI-Agenten (transcribe/cleanup/doctor/history).
import PackageDescription

#if os(Linux)
let linuxExcluded = ["AudioRecorder.swift", "AudioInputDevice.swift", "AudioDecoder.swift",
    "SileroModel.swift", "KeychainUpsert.swift", "PasteboardSnapshot.swift", "Diagnostics.swift",
    "ModelInstaller.swift", "TestDictationSession.swift", "BridgeToken.swift", "BridgeServer.swift", "BridgeRouter.swift",
    "BridgeProtocol.swift", "BridgePairing.swift", "BridgeLogFile.swift", "BridgeInterfaces.swift",
    "BridgeIdentity.swift"]
let package = Package(name: "StillePost", defaultLocalization: "de", targets: [
    .target(name: "StillePostCore", exclude: linuxExcluded, resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "stillepost-linux", dependencies: ["StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "LinuxCoreTests", dependencies: ["StillePostCore"], path: "Tests", sources: ["LinuxCoreTests", "StillePostCoreTests/AudioFailureLifecycleTests.swift", "StillePostCoreTests/HistoryCorrectionTests.swift", "StillePostCoreTests/HistoryManagementTests.swift", "StillePostCoreTests/HistoryPrivacyTests.swift", "StillePostCoreTests/HotkeyStateTests.swift", "StillePostCoreTests/PasteTargetPolicyTests.swift", "StillePostCoreTests/SelectionCleanupTests.swift", "StillePostCoreTests/TextDifferenceTests.swift", "StillePostCoreTests/VadSegmenterTests.swift", "StillePostCoreTests/WhisperHealthTests.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)])
])
#else
let package = Package(
    name: "StillePost",
    defaultLocalization: "de",
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
            resources: [.process("Resources")],
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

#endif
