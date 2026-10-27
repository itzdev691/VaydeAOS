// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VaydeAOS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VaydeAOS", targets: ["VaydeAOS"]),
        .library(name: "VaydeAOSCore", targets: ["VaydeAOSCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        .target(
            name: "VaydeAOSCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "VaydeAOS",
            dependencies: ["VaydeAOSCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
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
