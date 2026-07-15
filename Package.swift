// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SessionNest",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SessionNest", targets: ["SessionNest"])],
    targets: [
        .executableTarget(
            name: "SessionNest",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "SessionNestTests", dependencies: ["SessionNest"]),
    ]
)
