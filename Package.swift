// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nir-m-r2-macos",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .systemLibrary(
            name: "Chidapi",
            path: "Sources/Chidapi"
        ),
        .target(
            name: "NIRProtocol"
        ),
        .target(
            name: "HIDTransport",
            dependencies: ["Chidapi", "NIRProtocol"],
            linkerSettings: [
                .linkedLibrary("hidapi"),
                .unsafeFlags(["-L/opt/homebrew/lib"])
            ]
        ),
        .target(
            name: "NIRDevice",
            dependencies: ["HIDTransport", "NIRProtocol"]
        ),
        .executableTarget(
            name: "nir-cli",
            dependencies: ["NIRDevice", "NIRProtocol", "HIDTransport"]
        )
    ]
)
