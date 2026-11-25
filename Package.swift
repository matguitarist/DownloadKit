// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownloadKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // Downloads with progress, retries, resume and a SHA-256 check; GitHub release lookups. No SwiftUI.
        .library(name: "DownloadKit", targets: ["DownloadKit"]),
    ],
    targets: [
        .target(name: "DownloadKit"),
        .testTarget(name: "DownloadKitTests", dependencies: ["DownloadKit"]),
    ]
)
