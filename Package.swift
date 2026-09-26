// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Somabar",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SomabarCore", targets: ["SomabarCore"]),
        .library(name: "BarEngine", targets: ["BarEngine"]),
        .library(name: "NotchKit", targets: ["NotchKit"]),
    ],
    targets: [
        // Model, triggers, persistence. Pure Swift, no AppKit, unit-tested.
        .target(name: "SomabarCore"),
        // One backend per macOS version. The only code that knows how the bar hides and moves items.
        .target(name: "BarEngine", dependencies: ["SomabarCore"]),
        // Notch surface state and activities.
        .target(name: "NotchKit", dependencies: ["SomabarCore"]),

        .testTarget(name: "SomabarCoreTests", dependencies: ["SomabarCore"]),
        .testTarget(name: "BarEngineTests", dependencies: ["BarEngine"]),
        .testTarget(name: "NotchKitTests", dependencies: ["NotchKit"]),
    ],
    swiftLanguageModes: [.v6]
)
