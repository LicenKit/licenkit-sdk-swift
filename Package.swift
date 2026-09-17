// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LicenKit",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "LicenKit",
            targets: ["LicenKit"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "LicenKit",
            dependencies: [],
            path: "Sources/LicenKit"
        ),
        .testTarget(
            name: "LicenKitTests",
            dependencies: ["LicenKit"],
            path: "Tests/LicenKitTests"
        )
    ]
)
