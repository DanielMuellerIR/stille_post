// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StillePostClientCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "StillePostClientCore", targets: ["StillePostClientCore"])],
    targets: [
        .target(name: "StillePostClientCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "StillePostClientCoreTests", dependencies: ["StillePostClientCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
