// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaydeAOS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VaydeAOS", targets: ["VaydeAOS"]),
        .library(name: "VaydeAOSCore", targets: ["VaydeAOSCore"]),
    ],
    targets: [
        .target(
            name: "VaydeAOSCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "VaydeAOS",
            dependencies: ["VaydeAOSCore"],
            resources: [.process("Assets")],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(name: "VaydeAOSCoreTests", dependencies: ["VaydeAOSCore"]),
    ],
    swiftLanguageModes: [.v5]
)
