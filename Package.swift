// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "TokenMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore", path: "Sources/UsageCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TokenMeter", dependencies: ["UsageCore"], path: "Sources/TokenMeter",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SelfTest", dependencies: ["UsageCore"], path: "Sources/SelfTest",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
