// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MdrKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MdrKit", targets: ["MdrKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "MdrKit",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            resources: [.copy("Resources/Fonts"), .copy("Resources/tokens.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MdrKitTests",
            dependencies: ["MdrKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
