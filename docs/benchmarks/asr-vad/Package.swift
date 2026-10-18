// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ASRVADComparison",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: [])
    ],
    targets: [
        .target(name: "StillePostCore", path: "Core", resources: [.process("Resources")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "CompareAudio", dependencies: [
            "StillePostCore",
            .product(name: "FluidAudio", package: "FluidAudio")
        ], path: "Benchmark")
    ]
)
