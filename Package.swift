// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SEOpars",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SEOpars", targets: ["SEOpars"]),
        .executable(name: "seopars-cli", targets: ["seopars-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "SEOparsCore",
            dependencies: ["SwiftSoup"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "SEOpars", dependencies: ["SEOparsCore"]),
        .executableTarget(name: "seopars-cli", dependencies: ["SEOparsCore"]),
        .testTarget(name: "SEOparsCoreTests", dependencies: ["SEOparsCore"]),
    ]
)
