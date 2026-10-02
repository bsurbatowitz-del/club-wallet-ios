// swift-tools-version:5.9
// ClubCore: the platform-independent part of Club Wallet (pass signing, zip, spreadsheets,
// Google Wallet, email). It is used by the iPhone app and tested on macOS with `swift test`.
import PackageDescription

let package = Package(
    name: "ClubCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "ClubCore", targets: ["ClubCore"]),
    ],
    targets: [
        .target(name: "ClubCore", path: "Sources/ClubCore"),
        .testTarget(
            name: "ClubCoreTests",
            dependencies: ["ClubCore"],
            path: "Tests/ClubCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
