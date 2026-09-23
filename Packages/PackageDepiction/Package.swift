// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "PackageDepiction",
    platforms: [
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "PackageDepiction",
            targets: ["PackageDepiction"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/SDWebImage", from: "5.21.7"),
        .package(path: "../MarkdownView"),
        .package(url: "https://github.com/SnapKit/SnapKit", from: "6.0.0"),
        .package(url: "https://github.com/devxoul/Then", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "PackageDepiction",
            dependencies: [
                "SDWebImage",
                "MarkdownView",
                "SnapKit",
                "Then",
            ]
        ),
    ]
)
