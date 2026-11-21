// swift-tools-version:6.0
// Stille Post — lokale Diktier-App mit Whisper und optionaler Textbereinigung.
// Aufbau:
//   StillePostCore  — die gesamte Logik ohne GUI (Aufnahme, VAD, Whisper, Ollama, Verlauf).
//                     Bewusst getrennt, damit CLI und Tests dieselbe Logik nutzen wie die App.
//   StillePost      — die Menüleisten-App (Hotkey, Overlay, Verlaufsfenster).
//   stillepost-cli  — Kommandozeile für Skripte, Automatisierung und Tests.
import PackageDescription

#if os(Linux)
let macOnlySources = [
    "AudioRecorder.swift", "AudioInputDevice.swift", "AudioDecoder.swift", "SileroModel.swift",
    "KeychainUpsert.swift", "PasteboardSnapshot.swift", "BridgeToken.swift", "BridgeServer.swift",
    "BridgePairing.swift", "BridgeIdentity.swift"
]
let macOnlyTests = [
    "AppProfilePolicyTests.swift", "AudioFileImportTests.swift", "BridgeIdentityTests.swift",
    "BridgeInputTests.swift", "BridgeTests.swift", "CoreTests.swift", "SileroVadTests.swift"
].map { "StillePostCoreTests/" + $0 } + ["StillePostAppTests"]
let package = Package(name: "StillePost", defaultLocalization: "de", targets: [
    .target(name: "LinuxNative", path: "Sources/LinuxNative", linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("dl")]),
    .target(name: "StillePostCore", dependencies: ["LinuxNative"], exclude: macOnlySources, resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .executableTarget(name: "stillepost-linux", dependencies: ["StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "LinuxCoreTests", dependencies: ["StillePostCore"], path: "Tests", exclude: macOnlyTests,
            swiftSettings: [.swiftLanguageMode(.v6)])
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
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "StillePost",
            dependencies: [
                "StillePostCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // Das Release-Skript legt Sparkle im üblichen App-Bundle-Ordner ab.
                // SwiftPM ergänzt für Binär-Targets nur @loader_path (neben dem
                // Executable); diesen Bundle-rpath müssen wir daher selbst setzen.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"],
                             .when(configuration: .release))
            ]
        ),
        .target(name: "StillePostCLITerminal"),
        .executableTarget(
            name: "stillepost-cli",
            dependencies: ["StillePostCore", "StillePostCLITerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StillePostCoreTests",
            dependencies: ["StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StillePostAppTests",
            dependencies: ["StillePost", "StillePostCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

#endif
