// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "md2pdf",
    platforms: [
        .macOS(.v11)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "md2pdf",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [
                .process("github-markdown-light.css")
            ]
        ),
    ]
)