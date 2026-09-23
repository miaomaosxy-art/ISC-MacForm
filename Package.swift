// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Fail early with a clear message if TI/DLP Spectrum Library sources are missing.
let dlpDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("third_party/DLPSpectrumLibrary")
let dlpScanC = dlpDir.appendingPathComponent("dlpspec_scan.c")
if !FileManager.default.fileExists(atPath: dlpScanC.path) {
    fputs("""
    DLP Spectrum Library source not found.

    See:
      third_party/THIRD_PARTY.md

    Expected:
      \(dlpScanC.path)

    """, stderr)
    exit(1)
}

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
            name: "CDLPSpec",
            dependencies: [],
            path: "Sources/CDLPSpec",
            sources: ["dlpspec_bridge.c", "dlpspec_vendor_impl.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("TPL_NOLIB"),
                .headerSearchPath("../../third_party/DLPSpectrumLibrary"),
                .headerSearchPath("include")
            ]
        ),
        .target(
            name: "DLPSpec",
            dependencies: ["CDLPSpec", "NIRDevice"]
        ),
        .target(
            name: "NIRDevice",
            dependencies: ["HIDTransport", "NIRProtocol"]
        ),
        .executableTarget(
            name: "nir-cli",
            dependencies: ["NIRDevice", "NIRProtocol", "HIDTransport", "DLPSpec"]
        ),
        .executableTarget(
            name: "NIRMacApp",
            dependencies: ["NIRDevice", "NIRProtocol", "HIDTransport", "DLPSpec"]
        ),
        .testTarget(
            name: "NIRMacTests",
            dependencies: ["DLPSpec", "NIRDevice", "NIRProtocol", "HIDTransport"],
            exclude: ["Fixtures"]
        )
    ]
)
